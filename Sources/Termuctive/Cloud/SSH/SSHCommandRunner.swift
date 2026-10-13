import Foundation

/// A non-interactive command run on a cloud server over ssh.
struct CloudCommand: Equatable, Sendable {
    enum Remote: Equatable, Sendable {
        /// Arguments are quoted individually before the remote shell parses them.
        case arguments([String])
        /// A fixed script for the remote shell. Never build one from untrusted text.
        case script(String)
    }

    var alias: String
    var remote: Remote
    var input: Data?
    var timeout: TimeInterval
    var options: [String]

    init(
        alias: String,
        remote: Remote,
        input: Data? = nil,
        timeout: TimeInterval = 30,
        options: [String] = []
    ) {
        self.alias = alias
        self.remote = remote
        self.input = input
        self.timeout = timeout
        self.options = options
    }

    var remoteCommandLine: String {
        switch remote {
        case .arguments(let arguments):
            ShellQuoting.command(arguments)
        case .script(let script):
            script
        }
    }
}

enum CloudCommandError: LocalizedError, Equatable {
    case failed(command: String, status: Int32, message: String)
    case timedOut(command: String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .failed(_, let status, let message):
            message.isEmpty
                ? "The server command failed (exit \(status))."
                : message
        case .timedOut:
            "The server did not respond in time."
        case .invalidResponse(let detail):
            "The server sent an unexpected response: \(detail)"
        }
    }
}

protocol CloudCommandRunning: Sendable {
    func run(_ command: CloudCommand) async throws -> ProcessResult
}

extension CloudCommandRunning {
    /// Runs a command and throws unless it exits successfully.
    func output(_ command: CloudCommand) async throws -> ProcessResult {
        let result = try await run(command)
        if result.timedOut {
            throw CloudCommandError.timedOut(command: command.remoteCommandLine)
        }
        guard result.status == 0 else {
            throw CloudCommandError.failed(
                command: command.remoteCommandLine,
                status: result.status,
                message: Self.readableMessage(result.errorText)
            )
        }
        return result
    }

    func decode<Value: Decodable>(_ type: Value.Type, _ command: CloudCommand) async throws
        -> Value
    {
        let result = try await output(command)
        do {
            return try JSONDecoder().decode(type, from: result.output)
        } catch {
            throw CloudCommandError.invalidResponse(String(result.outputText.prefix(200)))
        }
    }

    private static func readableMessage(_ text: String) -> String {
        text.split(separator: "\n")
            .map { line in
                line.hasPrefix("tmc: ") ? String(line.dropFirst(5)) : String(line)
            }
            .joined(separator: "\n")
    }
}

struct SSHCommandRunner: CloudCommandRunning {
    let paths: SSHPaths

    func run(_ command: CloudCommand) async throws -> ProcessResult {
        try await ProcessRunner.run(
            "/usr/bin/ssh",
            arguments(for: command),
            input: command.input,
            timeout: command.timeout
        )
    }

    func arguments(for command: CloudCommand) -> [String] {
        ["-F", paths.configURL.path, "-T", "-o", "BatchMode=yes"]
            + command.options
            + [command.alias, "--", command.remoteCommandLine]
    }
}
