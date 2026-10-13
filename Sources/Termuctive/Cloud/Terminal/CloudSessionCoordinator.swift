import AppKit
import Combine
import Foundation
import Network

enum CloudFlow: Identifiable, Equatable {
    case setUpServer
    case connectProject(UUID)

    var id: String {
        switch self {
        case .setUpServer:
            "setUpServer"
        case .connectProject(let projectID):
            "connectProject-\(projectID.uuidString)"
        }
    }
}

/// Connects sidebar projects to cloud servers: decides how each pane launches, ends
/// remote sessions when panes are closed, and reconnects after sleep or network changes.
@MainActor
final class CloudSessionCoordinator: ObservableObject {
    @Published var presentedFlow: CloudFlow?
    @Published private(set) var errorMessage: String?

    let cloudStore: CloudStore
    let paths: SSHPaths
    let runner: any CloudCommandRunning
    let control: any CloudControlling

    private let store: WorkspaceStore
    private weak var sessions: TerminalSessionPool?
    private var cloudPaneProjects: [UUID: UUID] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var lastPathStatus: NWPath.Status?
    private var pendingRelaunch: Task<Void, Never>?
    private let observesSystemEvents: Bool

    init(
        store: WorkspaceStore,
        cloudStore: CloudStore,
        paths: SSHPaths = .live,
        runner: (any CloudCommandRunning)? = nil,
        control: (any CloudControlling)? = nil,
        observesSystemEvents: Bool = true
    ) {
        self.store = store
        self.cloudStore = cloudStore
        self.paths = paths
        self.runner = runner ?? SSHCommandRunner(paths: paths)
        self.control = control ?? CloudControlConnection(paths: paths)
        self.observesSystemEvents = observesSystemEvents
        cloudPaneProjects = currentCloudPaneProjects()

        cloudStore.$state
            .map(\.hosts)
            .removeDuplicates()
            .sink { [weak self] hosts in
                self?.writeSSHConfiguration(hosts: hosts)
            }
            .store(in: &cancellables)
        if observesSystemEvents {
            observeSystemEvents()
        }
    }

    func attach(sessions: TerminalSessionPool) {
        self.sessions = sessions
    }

    var client: TMCClient {
        TMCClient(runner: runner)
    }

    // MARK: Launching panes

    func launchSpec(for pane: TerminalPane) -> TerminalLaunchSpec {
        guard let project = store.document.project(containingTerminalWithID: pane.id),
            let binding = cloudStore.binding(forProjectID: project.id),
            let host = cloudStore.host(withID: binding.hostID)
        else {
            return .localShell
        }
        return .remote(
            CloudTerminalLauncher.launch(host: host, binding: binding, pane: pane, paths: paths)
        )
    }

    func isCloudProject(_ projectID: UUID) -> Bool {
        cloudStore.binding(forProjectID: projectID) != nil
    }

    func host(forProjectID projectID: UUID) -> CloudHost? {
        cloudStore.binding(forProjectID: projectID).flatMap {
            cloudStore.host(withID: $0.hostID)
        }
    }

    func hostName(forPaneID paneID: UUID) -> String? {
        store.document.project(containingTerminalWithID: paneID)
            .flatMap { host(forProjectID: $0.id) }?
            .name
    }

    // MARK: Pane lifecycle

    /// Ends the remote sessions of cloud panes the user closed. Removing a whole project
    /// only detaches, so its sessions stay on the server.
    func workspaceTerminalsChanged() {
        let current = currentCloudPaneProjects()
        let projectIDs = Set(store.document.projects.map(\.id))
        let removed = cloudPaneProjects.filter { paneID, projectID in
            current[paneID] == nil && projectIDs.contains(projectID)
        }
        cloudPaneProjects = current
        cloudStore.pruneBindings(keeping: projectIDs)

        for (paneID, projectID) in removed {
            guard let binding = cloudStore.binding(forProjectID: projectID),
                let host = cloudStore.host(withID: binding.hostID)
            else {
                continue
            }
            Task { [client, control] in
                await control.ensureMaster(alias: host.alias)
                try? await client.killSession(
                    alias: host.alias,
                    slug: binding.slug,
                    paneID: paneID
                )
            }
        }
    }

    private func currentCloudPaneProjects() -> [UUID: UUID] {
        var result: [UUID: UUID] = [:]
        for project in store.document.projects
        where cloudStore.binding(forProjectID: project.id) != nil {
            for item in project.items {
                for paneID in item.terminalIDs {
                    result[paneID] = project.id
                }
            }
        }
        return result
    }

    // MARK: Binding projects

    func connect(
        projectID: UUID,
        host: CloudHost,
        slug: String,
        remoteRoot: String
    ) async throws {
        await control.ensureMaster(alias: host.alias)
        _ = try await client.createProject(
            alias: host.alias,
            slug: slug,
            root: remoteRoot,
            owner: host.memberUser
        )
        // Joining the project group only applies to new logins.
        await control.reset(alias: host.alias)
        cloudStore.bind(
            CloudProjectBinding(
                projectID: projectID,
                hostID: host.id,
                slug: slug,
                remoteRoot: remoteRoot,
                role: .owner
            )
        )
        cloudPaneProjects = currentCloudPaneProjects()
        sessions?.relaunchPanes(withIDs: paneIDs(inProjectWithID: projectID))
    }

    /// Switches a project back to local terminals. Its server sessions keep running.
    func disconnect(projectID: UUID) {
        cloudStore.unbind(projectID: projectID)
        cloudPaneProjects = currentCloudPaneProjects()
        sessions?.relaunchPanes(withIDs: paneIDs(inProjectWithID: projectID))
    }

    private func paneIDs(inProjectWithID projectID: UUID) -> Set<UUID> {
        guard let project = store.document.projects.first(where: { $0.id == projectID }) else {
            return []
        }
        return project.items.reduce(into: Set<UUID>()) { $0.formUnion($1.terminalIDs) }
    }

    // MARK: Reconnecting

    func reconnectAll() {
        let aliases = cloudStore.hosts.map(\.alias)
        pendingRelaunch?.cancel()
        pendingRelaunch = Task { [weak self, control] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else {
                return
            }
            await control.resetAll(aliases: aliases)
            self?.sessions?.relaunchRemotePanes()
        }
    }

    private func observeSystemEvents() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reconnectAll()
            }
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let status = path.status
            Task { @MainActor in
                self?.networkPathChanged(to: status)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.mattceran.termuctive.network-path"))
        pathMonitor = monitor
    }

    private func networkPathChanged(to status: NWPath.Status) {
        defer {
            lastPathStatus = status
        }
        guard let lastPathStatus, status == .satisfied, lastPathStatus != .satisfied else {
            return
        }
        reconnectAll()
    }

    // MARK: Configuration

    private func writeSSHConfiguration(hosts: [CloudHost]) {
        guard !hosts.isEmpty || FileManager.default.fileExists(atPath: paths.configURL.path) else {
            return
        }
        do {
            try paths.prepareDirectories()
            try SSHConfigRenderer.render(hosts: hosts, paths: paths)
                .write(to: paths.configURL, atomically: true, encoding: .utf8)
        } catch {
            errorMessage =
                "Termuctive could not write its SSH settings. \(error.localizedDescription)"
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func presentError(_ message: String) {
        errorMessage = message
    }
}
