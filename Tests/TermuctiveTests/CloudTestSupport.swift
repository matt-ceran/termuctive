import Foundation

@testable import Termuctive

final class InMemoryCloudPersistence: CloudPersisting {
    private(set) var savedStates: [CloudState] = []
    private let initialState: CloudState?

    init(initialState: CloudState? = nil) {
        self.initialState = initialState
    }

    func load() throws -> CloudState? {
        initialState
    }

    func save(_ state: CloudState) throws {
        savedStates.append(state)
    }
}

final class RecordingCloudRunner: CloudCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CloudCommand] = []
    private let respond: (CloudCommand) -> ProcessResult

    init(
        respond: @escaping (CloudCommand) -> ProcessResult = { _ in
            ProcessResult(status: 0, output: Data(), error: Data(), timedOut: false)
        }
    ) {
        self.respond = respond
    }

    var commands: [CloudCommand] {
        lock.withLock { recorded }
    }

    func run(_ command: CloudCommand) async throws -> ProcessResult {
        lock.withLock { recorded.append(command) }
        return respond(command)
    }
}

struct NoOpCloudControl: CloudControlling {
    func ensureMaster(alias: String) async {}
    func reset(alias: String) async {}
    func resetAll(aliases: [String]) async {}
}

func makeTemporarySSHPaths() -> SSHPaths {
    SSHPaths(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("termuctive-ssh-\(UUID().uuidString.prefix(8))")
    )
}

@MainActor
func makeTestCloud(
    store: WorkspaceStore,
    state: CloudState? = nil,
    runner: (any CloudCommandRunning)? = nil
) -> (CloudSessionCoordinator, CloudStore) {
    let cloudStore = CloudStore(persistence: InMemoryCloudPersistence(initialState: state))
    let coordinator = CloudSessionCoordinator(
        store: store,
        cloudStore: cloudStore,
        paths: makeTemporarySSHPaths(),
        runner: runner ?? RecordingCloudRunner(),
        control: NoOpCloudControl(),
        observesSystemEvents: false
    )
    return (coordinator, cloudStore)
}
