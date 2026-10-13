import Foundation

protocol CloudControlling: Sendable {
    func ensureMaster(alias: String) async
    func reset(alias: String) async
    func resetAll(aliases: [String]) async
    /// Forwards a port on this Mac to the same port on the server through the master.
    func forward(port: Int, alias: String) async -> Bool
    func cancelForward(port: Int, alias: String) async
}

/// Keeps one multiplexed ssh connection per host for quick control-plane commands.
///
/// The master is started from a plain process with no terminal, so it never inherits
/// a pane's pseudo-terminal. Terminal panes deliberately use their own connections.
actor CloudControlConnection: CloudControlling {
    private let paths: SSHPaths
    private var lastVerified: [String: Date] = [:]
    private let verificationInterval: TimeInterval = 20

    init(paths: SSHPaths) {
        self.paths = paths
    }

    func ensureMaster(alias: String) async {
        if let verified = lastVerified[alias],
            Date().timeIntervalSince(verified) < verificationInterval
        {
            return
        }
        if await isAlive(alias: alias) {
            lastVerified[alias] = Date()
            return
        }
        let started = try? await ProcessRunner.run(
            "/usr/bin/ssh",
            [
                "-F", paths.configURL.path,
                "-o", "BatchMode=yes",
                "-o", "ControlMaster=yes",
                "-o", "ControlPersist=600",
                "-MNf", alias,
            ],
            timeout: 20,
            collectsOutput: false
        )
        if started?.succeeded == true {
            lastVerified[alias] = Date()
        }
    }

    func reset(alias: String) async {
        lastVerified[alias] = nil
        _ = try? await ProcessRunner.run(
            "/usr/bin/ssh",
            ["-F", paths.configURL.path, "-O", "exit", alias],
            timeout: 5
        )
    }

    func resetAll(aliases: [String]) async {
        for alias in aliases {
            await reset(alias: alias)
        }
    }

    func forward(port: Int, alias: String) async -> Bool {
        let result = try? await ProcessRunner.run(
            "/usr/bin/ssh",
            ["-F", paths.configURL.path, "-O", "forward", "-L", Self.forwardSpec(port), alias],
            timeout: 10
        )
        return result?.succeeded == true
    }

    func cancelForward(port: Int, alias: String) async {
        _ = try? await ProcessRunner.run(
            "/usr/bin/ssh",
            ["-F", paths.configURL.path, "-O", "cancel", "-L", Self.forwardSpec(port), alias],
            timeout: 10
        )
    }

    static func forwardSpec(_ port: Int) -> String {
        "127.0.0.1:\(port):127.0.0.1:\(port)"
    }

    private func isAlive(alias: String) async -> Bool {
        let result = try? await ProcessRunner.run(
            "/usr/bin/ssh",
            ["-F", paths.configURL.path, "-O", "check", alias],
            timeout: 5
        )
        return result?.succeeded == true
    }
}
