import Foundation

/// Moves a sidebar project onto a cloud server: scan, copy while work continues, then
/// stop local terminals, catch up and open a cloud copy of the project beside the original.
@MainActor
final class ProjectMove: ObservableObject {
    enum Step: Equatable {
        case chooseServer
        case scanning(String)
        case review
        case copying
        case readyToSwitch
        case switching(String)
        case done(projectID: UUID)
        case failed(String)
    }

    @Published var step: Step = .chooseServer
    @Published var manifest: TransferManifest?
    @Published var hostID: UUID?
    @Published var slug: String
    @Published private(set) var engine: TransferEngine?

    let projectID: UUID
    private let store: WorkspaceStore
    private let sessions: TerminalSessionPool
    private let notes: NoteSessionPool
    private let cloud: CloudSessionCoordinator
    private let scanner: ProjectScanner

    init(
        projectID: UUID,
        store: WorkspaceStore,
        sessions: TerminalSessionPool,
        notes: NoteSessionPool,
        cloud: CloudSessionCoordinator,
        scanner: ProjectScanner = ProjectScanner()
    ) {
        self.projectID = projectID
        self.store = store
        self.sessions = sessions
        self.notes = notes
        self.cloud = cloud
        self.scanner = scanner
        let name = store.document.projects.first { $0.id == projectID }?.name ?? "project"
        slug = CloudSlug.make(from: name)
        hostID = cloud.cloudStore.hosts.first?.id
    }

    var project: TerminalProject? {
        store.document.projects.first { $0.id == projectID }
    }

    var host: CloudHost? {
        hostID.flatMap { cloud.cloudStore.host(withID: $0) }
    }

    /// Why this project can't be moved: it already has a cloud copy, and moving again would
    /// copy this Mac's older files over work done there and delete its newer commits.
    var alreadyMovedMessage: String? {
        guard let project,
            let copy = cloud.cloudStore.binding(forRemoteRoot: project.rootDirectory),
            copy.projectID != projectID
        else {
            return nil
        }
        let copyName =
            store.document.projects.first { $0.id == copy.projectID }?.name
            ?? "\(project.name) (Cloud)"
        let hostName = cloud.cloudStore.host(withID: copy.hostID)?.name ?? "a server"
        return "\(project.name) is already in the cloud as \(copyName) on \(hostName). "
            + "Moving it again would replace work done there with this Mac's older copy, "
            + "so keep working in \(copyName)."
    }

    var isWorking: Bool {
        switch step {
        case .scanning, .copying, .switching:
            true
        default:
            engine?.isRunning == true
        }
    }

    // MARK: Steps

    func scan() async {
        guard let project else {
            step = .failed("The project no longer exists.")
            return
        }
        if let alreadyMovedMessage {
            step = .failed(alreadyMovedMessage)
            return
        }
        step = .scanning("Starting")
        do {
            manifest = try await scanner.scan(
                projectID: project.id,
                projectName: project.name,
                root: project.rootDirectory,
                paneDirectories: paneDirectories(in: project),
                progress: { [weak self] message in
                    self?.step = .scanning(message)
                }
            )
            step = .review
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    func setSelected(_ selected: Bool, forItemID id: String) {
        guard let index = manifest?.items.firstIndex(where: { $0.id == id }) else {
            return
        }
        manifest?.items[index].selected = selected
    }

    /// Keeps only worktrees used within `interval`, plus any with open panes.
    func selectWorktrees(usedWithin interval: TimeInterval, now: Date = Date()) {
        guard var manifest, let project else {
            return
        }
        let open = paneDirectories(in: project)
        for index in manifest.items.indices where manifest.items[index].kind == .worktree {
            let item = manifest.items[index]
            let recent =
                (item.lastActivity.map { now.timeIntervalSince($0) } ?? .infinity) < interval
            let hasPane = open.contains {
                $0 == item.localPath || $0.hasPrefix(item.localPath + "/")
            }
            manifest.items[index].selected = recent || hasPane
        }
        self.manifest = manifest
    }

    func setSelected(_ selected: Bool, forGroup group: TransferItem.Group) {
        guard var manifest else {
            return
        }
        for index in manifest.items.indices where manifest.items[index].group == group {
            manifest.items[index].selected = selected
        }
        self.manifest = manifest
    }

    /// The first, long copy. The project keeps working on this Mac meanwhile.
    func startCopy() async {
        guard let manifest, let host, CloudSlug.isValid(slug) else {
            return
        }
        if let alreadyMovedMessage {
            step = .failed(alreadyMovedMessage)
            return
        }
        await cloud.control.ensureMaster(alias: host.alias)
        let engine = TransferEngine(
            manifest: manifest,
            host: host,
            slug: slug,
            runner: cloud.runner,
            paths: cloud.paths
        )
        self.engine = engine
        cloud.activeMove = self
        step = .copying
        let succeeded = await engine.run(.initial)
        await cloud.control.reset(alias: host.alias)
        if succeeded {
            step = .readyToSwitch
        } else if case .failed(let message) = engine.state {
            step = .failed(message)
        } else {
            step = .review
        }
        if cloud.activeMove === self, !succeeded {
            cloud.activeMove = nil
        }
    }

    /// Stops local terminals, copies the last changes and opens the cloud copy.
    func switchToCloud() async {
        guard let manifest, let host, let engine, let project else {
            return
        }
        step = .switching("Stopping terminals on this Mac")
        sessions.stopPanes(withIDs: paneIDs(in: project))

        step = .switching("Copying the latest changes")
        guard await engine.run(.final) else {
            if case .failed(let message) = engine.state {
                step = .failed(message)
            } else {
                step = .readyToSwitch
            }
            cloud.activeMove = nil
            return
        }

        step = .switching("Opening the cloud project")
        guard
            let duplicate = store.duplicateProject(
                withID: project.id,
                name: "\(project.name) (Cloud)"
            )
        else {
            step = .failed("Termuctive could not create the cloud project in the sidebar.")
            cloud.activeMove = nil
            return
        }
        do {
            try notes.duplicateNotes(duplicate.noteIDs)
        } catch {
            store.presentError("Some notes could not be copied: \(error.localizedDescription)")
        }
        cloud.cloudStore.bind(
            CloudProjectBinding(
                projectID: duplicate.projectID,
                hostID: host.id,
                slug: slug,
                remoteRoot: manifest.projectRoot,
                role: .owner,
                sharedPaths: manifest.selectedItems
                    .filter { $0.kind == .relatedFolder }
                    .map(\.remotePath)
            )
        )
        cloud.workspaceTerminalsChanged()
        openSetupSpace(inProjectWithID: duplicate.projectID, manifest: manifest)
        cloud.activeMove = nil
        step = .done(projectID: duplicate.projectID)
    }

    func cancel() {
        engine?.cancel()
    }

    // MARK: Helpers

    private func openSetupSpace(inProjectWithID projectID: UUID, manifest: TransferManifest) {
        store.addSpace(toFolderWithID: nil, inProjectWithID: projectID)
        guard let spaceID = store.document.selectedSpaceID,
            let paneID = store.focusedPaneID
        else {
            return
        }
        store.renameItem(withID: spaceID, inProject: projectID, to: "Cloud Setup")
        let openDirectories = project.map(paneDirectories(in:)) ?? []
        cloud.queueInitialCommand(
            Self.setupCommand(for: manifest, paneDirectories: openDirectories, now: Date()),
            forPaneID: paneID
        )
    }

    /// Installs dependencies for the project, worktrees with open panes and the few most
    /// recently used worktrees, then prints the checklist of sign-ins that need a person.
    /// Other worktrees can be prepared later with `tmc hydrate`.
    static func setupCommand(
        for manifest: TransferManifest,
        paneDirectories: [String],
        now: Date
    ) -> String {
        let worktrees = manifest.selectedItems.filter { $0.kind == .worktree }
        let open = worktrees.filter { item in
            paneDirectories.contains {
                $0 == item.remotePath || $0.hasPrefix(item.remotePath + "/")
            }
        }
        let recent =
            worktrees
            .filter { item in
                !open.contains(item)
                    && (item.lastActivity.map { now.timeIntervalSince($0) } ?? .infinity)
                        < TransferDefaults.hydrateWindow
            }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            .prefix(TransferDefaults.hydrateRecentLimit)
        let tmc = TMCClient.executable
        var steps = ([manifest.projectRoot] + (open + recent).map(\.remotePath)).map { root in
            "\(tmc) hydrate --root \(ShellQuoting.quote(root))"
        }
        steps.append("\(tmc) checklist --root \(ShellQuoting.quote(manifest.projectRoot))")
        return steps.joined(separator: "; ")
    }

    private func paneDirectories(in project: TerminalProject) -> [String] {
        project.items.flatMap(\.terminalSpaces).flatMap { space in
            space.layout.orderedTerminalIDs.compactMap {
                space.layout.terminal(withID: $0)?.workingDirectory
            }
        }
    }

    private func paneIDs(in project: TerminalProject) -> Set<UUID> {
        project.items.reduce(into: Set<UUID>()) { $0.formUnion($1.terminalIDs) }
    }
}
