import Foundation

struct TMCVersion: Decodable, Equatable {
    let version: String
    let protocolVersion: Int

    private enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
    }
}

struct RemoteProject: Decodable, Equatable {
    let slug: String
    let root: String
    let owner: String
    let members: [String]
}

struct RemoteSession: Decodable, Equatable {
    let pane: UUID
    let created: Int
    let activity: Int
    let attached: Bool
    let pid: Int
    let command: String
    let cwd: String
}

struct CloudServerStatus: Decodable, Equatable {
    struct Memory: Decodable, Equatable {
        let totalBytes: Int64
        let availableBytes: Int64
    }

    struct Disk: Decodable, Equatable {
        let path: String
        let totalBytes: Int64
        let freeBytes: Int64
    }

    struct GPU: Decodable, Equatable {
        let name: String
        let memoryTotalMB: Int
        let memoryUsedMB: Int
        let utilizationPercent: Int
    }

    struct Tailscale: Decodable, Equatable {
        let state: String?
        let dnsName: String?
        let addresses: [String]?
    }

    struct Tools: Decodable, Equatable {
        let tmux: String?
        let git: String?
        let node: String?
        let claude: String?
        let gh: String?
        let aws: String?
    }

    let toolkit: TMCVersion
    let user: String
    let home: String
    let hostname: String
    let os: String
    let arch: String
    let cpuCount: Int
    let memory: Memory
    let disk: Disk
    let rebootRequired: Bool
    let gpus: [GPU]
    let tailscale: Tailscale
    let tools: Tools
    let projects: [RemoteProject]
    let sessions: [RemoteSession]?
}

/// Typed access to the server toolkit's `tmc` command.
struct TMCClient {
    static let protocolVersion = 1
    static let executable = "/opt/termuctive/bin/tmc"

    let runner: any CloudCommandRunning

    func version(alias: String) async throws -> TMCVersion {
        try await runner.decode(
            TMCVersion.self,
            CloudCommand(alias: alias, remote: .arguments([Self.executable, "version"]))
        )
    }

    func status(alias: String, slug: String? = nil) async throws -> CloudServerStatus {
        var arguments = [Self.executable, "status"]
        if let slug {
            arguments += ["--slug", slug]
        }
        return try await runner.decode(
            CloudServerStatus.self,
            CloudCommand(alias: alias, remote: .arguments(arguments), timeout: 45)
        )
    }

    func createProject(
        alias: String,
        slug: String,
        root: String,
        owner: String
    ) async throws -> RemoteProject {
        try await runner.decode(
            RemoteProject.self,
            CloudCommand(
                alias: alias,
                remote: .arguments([
                    "sudo", "-n", Self.executable, "admin", "project-create",
                    "--slug", slug, "--root", root, "--owner", owner,
                ])
            )
        )
    }

    func listSessions(alias: String, slug: String) async throws -> [RemoteSession] {
        try await runner.decode(
            [RemoteSession].self,
            CloudCommand(
                alias: alias, remote: .arguments([Self.executable, "list", "--slug", slug]))
        )
    }

    func killSession(alias: String, slug: String, paneID: UUID) async throws {
        _ = try await runner.output(
            CloudCommand(
                alias: alias,
                remote: .arguments([
                    Self.executable, "kill", "--slug", slug,
                    "--pane", paneID.uuidString.lowercased(),
                ])
            )
        )
    }

    static func attachCommand(
        slug: String,
        paneID: UUID,
        workingDirectory: String,
        initialCommand: String? = nil
    ) -> [String] {
        var arguments = [
            executable, "attach",
            "--protocol", String(protocolVersion),
            "--slug", slug,
            "--pane", paneID.uuidString.lowercased(),
            "--cwd", workingDirectory,
        ]
        if let initialCommand {
            arguments += ["--command", initialCommand]
        }
        return arguments
    }
}
