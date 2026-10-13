import Foundation

protocol CloudPersisting {
    func load() throws -> CloudState?
    func save(_ state: CloudState) throws
}

/// Cloud hosts and project bindings live beside the workspace file rather than in it,
/// so an older Termuctive build that rewrites workspace.json cannot drop them.
struct CloudFileStore: CloudPersisting {
    let fileURL: URL

    static var live: CloudFileStore {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return CloudFileStore(
            fileURL:
                applicationSupport
                .appendingPathComponent("Termuctive", isDirectory: true)
                .appendingPathComponent("cloud.json")
        )
    }

    func load() throws -> CloudState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let state = try JSONDecoder().decode(
            CloudState.self,
            from: Data(contentsOf: fileURL)
        )
        guard state.schemaVersion <= CloudState.currentSchemaVersion else {
            throw CloudFileStoreError.unsupportedSchema(state.schemaVersion)
        }
        return state
    }

    func save(_ state: CloudState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}

enum CloudFileStoreError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "The saved cloud settings use unsupported schema version \(version)."
        }
    }
}

@MainActor
final class CloudStore: ObservableObject {
    @Published private(set) var state: CloudState
    @Published private(set) var errorMessage: String?

    private let persistence: any CloudPersisting
    /// Set when the saved file could not be read, so it is never overwritten by accident.
    private let isReadOnly: Bool

    init(persistence: any CloudPersisting = CloudFileStore.live) {
        self.persistence = persistence
        do {
            state = try persistence.load() ?? CloudState()
            isReadOnly = false
        } catch {
            state = CloudState()
            isReadOnly = true
            errorMessage = error.localizedDescription
        }
    }

    var hosts: [CloudHost] {
        state.hosts
    }

    func host(withID id: UUID) -> CloudHost? {
        state.host(withID: id)
    }

    func binding(forProjectID projectID: UUID) -> CloudProjectBinding? {
        state.binding(forProjectID: projectID)
    }

    var boundProjectIDs: Set<UUID> {
        Set(state.bindings.map(\.projectID))
    }

    func addOrUpdate(_ host: CloudHost) {
        if let index = state.hosts.firstIndex(where: { $0.id == host.id }) {
            state.hosts[index] = host
        } else {
            state.hosts.append(host)
        }
        save()
    }

    func removeHost(withID id: UUID) {
        state.hosts.removeAll { $0.id == id }
        state.bindings.removeAll { $0.hostID == id }
        save()
    }

    func bind(_ binding: CloudProjectBinding) {
        state.bindings.removeAll { $0.projectID == binding.projectID }
        state.bindings.append(binding)
        save()
    }

    func unbind(projectID: UUID) {
        state.bindings.removeAll { $0.projectID == projectID }
        save()
    }

    /// Forgets bindings for projects that no longer exist in the workspace.
    func pruneBindings(keeping projectIDs: Set<UUID>) {
        let pruned = state.bindings.filter { projectIDs.contains($0.projectID) }
        guard pruned.count != state.bindings.count else {
            return
        }
        state.bindings = pruned
        save()
    }

    func dismissError() {
        errorMessage = nil
    }

    private func save() {
        guard !isReadOnly else {
            return
        }
        do {
            try persistence.save(state)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
