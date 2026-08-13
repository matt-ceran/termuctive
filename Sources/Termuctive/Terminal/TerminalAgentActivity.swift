import Darwin
import Foundation

enum TerminalAgentKind: String, CaseIterable, Hashable, Sendable {
    case aider
    case claude
    case codex
    case copilot
    case gemini
    case goose
    case openCode

    var displayName: String {
        switch self {
        case .aider:
            "Aider"
        case .claude:
            "Claude"
        case .codex:
            "Codex"
        case .copilot:
            "Copilot"
        case .gemini:
            "Gemini"
        case .goose:
            "Goose"
        case .openCode:
            "OpenCode"
        }
    }
}

enum TerminalAgentActivityPhase: Int, Comparable, Sendable {
    case absent
    case active

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct TerminalAgentActivity: Equatable, Sendable {
    var phase: TerminalAgentActivityPhase
    var kinds: Set<TerminalAgentKind>

    static let absent = TerminalAgentActivity(phase: .absent, kinds: [])

    static func active(_ kinds: Set<TerminalAgentKind>) -> Self {
        TerminalAgentActivity(phase: .active, kinds: kinds)
    }
}

struct AgentProcessRecord: Equatable, Sendable {
    let processID: Int32
    let executablePath: String
    let processName: String
    let arguments: [String]
}

struct AgentShellIdentity: Equatable, Sendable {
    let processID: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

struct AgentProcessSample: Equatable, Sendable {
    let processID: Int32
    let kind: TerminalAgentKind
}

struct AgentProcessSnapshot: Equatable, Sendable {
    let shellIdentity: AgentShellIdentity
    let processes: [AgentProcessSample]
}

enum AgentProcessInspection: Equatable, Sendable {
    case shellTerminated
    case snapshot(AgentProcessSnapshot)
    case unavailable
}

protocol AgentProcessInspecting {
    func shellIdentity(shellPID: Int32) -> AgentShellIdentity?
    func inspect(
        shellPID: Int32,
        expectedIdentity: AgentShellIdentity
    ) -> AgentProcessInspection
}

struct MacAgentProcessInspector: AgentProcessInspecting {
    func shellIdentity(shellPID: Int32) -> AgentShellIdentity? {
        guard let shellInfo = Self.processInfo(for: shellPID),
            shellInfo.processID == shellPID
        else {
            return nil
        }
        return Self.identity(from: shellInfo)
    }

    func inspect(
        shellPID: Int32,
        expectedIdentity: AgentShellIdentity
    ) -> AgentProcessInspection {
        guard let shellInfo = Self.processInfo(for: shellPID),
            shellInfo.processID == shellPID
        else {
            return Self.processExists(shellPID) ? .unavailable : .shellTerminated
        }
        let identity = Self.identity(from: shellInfo)
        guard identity == expectedIdentity else {
            return .shellTerminated
        }
        guard shellInfo.foregroundProcessGroupID > 0 else {
            return .unavailable
        }

        let foregroundProcessGroupID = shellInfo.foregroundProcessGroupID
        guard let processIDs = Self.processIDs(inProcessGroup: foregroundProcessGroupID) else {
            return .unavailable
        }
        let samples = processIDs.compactMap { processID -> AgentProcessSample? in
            guard let processInfo = Self.processInfo(for: processID),
                processInfo.processGroupID == foregroundProcessGroupID
            else {
                return nil
            }

            let executablePath = Self.processPath(for: processID)
            let processName =
                executablePath.isEmpty
                ? Self.processName(for: processID)
                : ""
            let arguments =
                TerminalAgentProcessMatcher.needsArguments(
                    executablePath: executablePath,
                    processName: processName
                )
                ? Self.processArguments(for: processID)
                : []
            let record = AgentProcessRecord(
                processID: processID,
                executablePath: executablePath,
                processName: processName,
                arguments: arguments
            )
            guard let kind = TerminalAgentProcessMatcher.kind(for: record) else {
                return nil
            }
            return AgentProcessSample(
                processID: processID,
                kind: kind
            )
        }

        guard let finalShellInfo = Self.processInfo(for: shellPID) else {
            return Self.processExists(shellPID) ? .unavailable : .shellTerminated
        }
        guard Self.identity(from: finalShellInfo) == expectedIdentity else {
            return .shellTerminated
        }
        guard finalShellInfo.foregroundProcessGroupID == foregroundProcessGroupID else {
            return .unavailable
        }
        return .snapshot(
            AgentProcessSnapshot(shellIdentity: identity, processes: samples)
        )
    }

    private static func processInfo(for processID: Int32) -> TMCProcessInfo? {
        var processInfo = TMCProcessInfo()
        guard TMCReadProcessInfo(processID, &processInfo) == 1 else {
            return nil
        }
        return processInfo
    }

    private static func processIDs(inProcessGroup processGroupID: Int32) -> [Int32]? {
        var capacity = 16

        for _ in 0..<3 {
            var processIDs = [Int32](repeating: 0, count: capacity)
            let count = processIDs.withUnsafeMutableBufferPointer { buffer in
                TMCListProcessGroupPIDs(
                    processGroupID,
                    buffer.baseAddress,
                    Int32(buffer.count)
                )
            }
            guard count >= 0 else {
                return nil
            }
            if count < capacity || capacity == 4_096 {
                return Array(processIDs.prefix(min(Int(count), capacity))).filter { $0 > 0 }
            }
            capacity = min(capacity * 2, 4_096)
        }
        return nil
    }

    private static func identity(from processInfo: TMCProcessInfo) -> AgentShellIdentity {
        AgentShellIdentity(
            processID: processInfo.processID,
            startSeconds: processInfo.startSeconds,
            startMicroseconds: processInfo.startMicroseconds
        )
    }

    private static func processExists(_ processID: Int32) -> Bool {
        if Darwin.kill(processID, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }

    private static func processPath(for processID: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            TMCReadProcessPath(processID, pointer.baseAddress, Int32(pointer.count))
        }
        guard length > 0 else {
            return ""
        }
        return String(cString: buffer)
    }

    private static func processName(for processID: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 1_024)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            TMCReadProcessName(processID, pointer.baseAddress, Int32(pointer.count))
        }
        guard length > 0 else {
            return ""
        }
        return String(cString: buffer)
    }

    static func processArguments(for processID: Int32) -> [String] {
        var buffer = [CChar](repeating: 0, count: 32_768)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            TMCReadProcessArguments(processID, pointer.baseAddress, Int32(pointer.count))
        }
        guard length > 0 else {
            return []
        }

        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return bytes.split(separator: 0).map { bytes in
            String(decoding: bytes, as: UTF8.self)
        }
    }
}

enum TerminalAgentProcessMatcher {
    static func needsArguments(executablePath: String, processName: String) -> Bool {
        let executableName = normalizedExecutableName(executablePath)
        let fallbackName = normalizedExecutableName(processName)
        return switch executableName.isEmpty ? fallbackName : executableName {
        case "node", "nodejs", "bun", "deno", "gh", "python":
            true
        case let name where name.hasPrefix("python3"):
            true
        default:
            false
        }
    }

    static func kind(for record: AgentProcessRecord) -> TerminalAgentKind? {
        let executableName = normalizedExecutableName(record.executablePath)
        let processName = normalizedExecutableName(record.processName)
        if let kind = nativeKind(for: executableName)
            ?? nativeKind(for: processName)
        {
            return kind
        }

        let effectiveExecutable = executableName.isEmpty ? processName : executableName
        switch effectiveExecutable {
        case "node", "nodejs", "bun", "deno":
            return javascriptWrapperKind(arguments: record.arguments)
        case let name where name == "python" || name.hasPrefix("python3"):
            return pythonWrapperKind(arguments: record.arguments)
        case "gh":
            return githubCLIKind(arguments: record.arguments)
        default:
            return nil
        }
    }

    private static func nativeKind(for executableName: String) -> TerminalAgentKind? {
        switch executableName {
        case "aider", "aider-chat", "aider_chat":
            .aider
        case "claude":
            .claude
        case "codex":
            .codex
        case "copilot", "github-copilot-cli":
            .copilot
        case "gemini":
            .gemini
        case "goose":
            .goose
        case "opencode":
            .openCode
        default:
            nil
        }
    }

    private static func javascriptWrapperKind(arguments: [String]) -> TerminalAgentKind? {
        guard let launchTarget = javascriptLaunchTarget(arguments: arguments) else {
            return nil
        }
        let normalized = launchTarget.lowercased().replacingOccurrences(of: "\\", with: "/")
        let basename = normalizedExecutableName(normalized)

        if normalized.contains("/node_modules/@openai/codex/")
            || normalized.contains("/@openai/codex/")
            || basename == "codex.js"
        {
            return .codex
        }
        if normalized.contains("/node_modules/@anthropic-ai/claude-code/")
            || normalized.contains("/@anthropic-ai/claude-code/")
            || basename == "claude.js"
        {
            return .claude
        }
        if normalized.contains("/node_modules/@google/gemini-cli/")
            || normalized.contains("/@google/gemini-cli/")
            || basename == "gemini.js"
        {
            return .gemini
        }
        if normalized.contains("/node_modules/opencode-ai/")
            || normalized.contains("/opencode-ai/")
            || basename == "opencode.js"
        {
            return .openCode
        }
        if normalized.contains("/node_modules/@github/copilot/")
            || normalized.contains("/@github/copilot/")
            || basename == "copilot.js"
        {
            return .copilot
        }
        return nil
    }

    private static func javascriptLaunchTarget(arguments: [String]) -> String? {
        var arguments = Array(arguments.dropFirst())
        if arguments.first == "run" || arguments.first == "x" {
            arguments.removeFirst()
        }

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                return arguments.dropFirst(index + 1).first
            }
            if !argument.hasPrefix("-") {
                return argument
            }
            index += 1
        }
        return nil
    }

    private static func pythonWrapperKind(arguments: [String]) -> TerminalAgentKind? {
        let arguments = Array(arguments.dropFirst())
        if let moduleIndex = arguments.firstIndex(of: "-m"),
            arguments.indices.contains(moduleIndex + 1),
            ["aider", "aider.__main__", "aider_chat"].contains(
                arguments[moduleIndex + 1].lowercased()
            )
        {
            return .aider
        }

        guard let script = arguments.first(where: { !$0.hasPrefix("-") }) else {
            return nil
        }
        let basename = normalizedExecutableName(script)
        return ["aider", "aider.py", "aider-chat", "aider_chat.py"].contains(basename)
            ? .aider
            : nil
    }

    private static func githubCLIKind(arguments: [String]) -> TerminalAgentKind? {
        guard arguments.count > 1,
            arguments[1].lowercased() == "copilot"
        else {
            return nil
        }
        return .copilot
    }

    private static func normalizedExecutableName(_ value: String) -> String {
        guard !value.isEmpty else {
            return ""
        }
        return URL(fileURLWithPath: value).lastPathComponent.lowercased()
    }
}
