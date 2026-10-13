import Darwin
import Foundation

struct RemotePort: Decodable, Equatable {
    let port: Int
    let pid: Int
    let command: String
}

/// Mirrors dev servers running in cloud sessions onto the same ports on this Mac, so
/// http://localhost:5173 keeps working after a project moves to the cloud.
@MainActor
final class CloudPortForwarder: ObservableObject {
    struct Forward: Equatable, Hashable {
        let hostID: UUID
        let port: Int
        let command: String
    }

    @Published private(set) var forwards: [Forward] = []
    /// Ports in use on this Mac by something else, so they cannot be forwarded.
    @Published private(set) var blockedPorts: [Int] = []

    private let cloudStore: CloudStore
    private let runner: any CloudCommandRunning
    private let control: any CloudControlling
    private let isLocalPortFree: (Int) -> Bool
    private var loop: Task<Void, Never>?

    init(
        cloudStore: CloudStore,
        runner: any CloudCommandRunning,
        control: any CloudControlling,
        isLocalPortFree: @escaping (Int) -> Bool = LocalPort.isAvailable
    ) {
        self.cloudStore = cloudStore
        self.runner = runner
        self.control = control
        self.isLocalPortFree = isLocalPortFree
    }

    func start(interval: TimeInterval = 5) {
        guard loop == nil else {
            return
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Forgets forwards whose control connection was reset; the next refresh restores them.
    func connectionsReset() {
        forwards = []
    }

    func refresh() async {
        let hostIDs = Set(cloudStore.state.bindings.map(\.hostID))
        for host in cloudStore.hosts where hostIDs.contains(host.id) {
            await refresh(host)
        }
        forwards.removeAll { !hostIDs.contains($0.hostID) }
    }

    private func refresh(_ host: CloudHost) async {
        await control.ensureMaster(alias: host.alias)
        guard
            let ports = try? await runner.decode(
                [RemotePort].self,
                CloudCommand(
                    alias: host.alias, remote: .arguments([TMCClient.executable, "ports"]))
            )
        else {
            return
        }
        let existing = forwards.filter { $0.hostID == host.id }
        let wanted = Dictionary(
            ports.map { ($0.port, $0) }, uniquingKeysWith: { first, _ in first })

        for forward in existing where wanted[forward.port] == nil {
            await control.cancelForward(port: forward.port, alias: host.alias)
            forwards.removeAll { $0 == forward }
        }
        var blocked: [Int] = []
        for (port, remote) in wanted.sorted(by: { $0.key < $1.key })
        where !existing.contains(where: { $0.port == port }) {
            guard !forwards.contains(where: { $0.port == port }), isLocalPortFree(port) else {
                blocked.append(port)
                continue
            }
            if await control.forward(port: port, alias: host.alias) {
                forwards.append(Forward(hostID: host.id, port: port, command: remote.command))
            }
        }
        forwards.sort { $0.port < $1.port }
        blockedPorts = blocked
    }
}

enum LocalPort {
    static func isAvailable(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return false
        }
        defer {
            close(descriptor)
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
