import Foundation

struct RemoteTerminalLaunch: Equatable {
    let executable: String
    let arguments: [String]
    let hostLabel: String
    var reconnectPolicy = TerminalReconnectPolicy()
    /// Where pasted images and dropped files are uploaded so remote programs can read them.
    var uploadTarget: RemoteUploadTarget?
}

struct RemoteUploadTarget: Equatable {
    let sshConfigPath: String
    let alias: String
    /// The folder on the server that receives uploads.
    let directory: String
}

enum TerminalLaunchSpec: Equatable {
    case localShell
    case remote(RemoteTerminalLaunch)

    var remote: RemoteTerminalLaunch? {
        if case .remote(let launch) = self {
            return launch
        }
        return nil
    }
}

enum TerminalProcessExit: Equatable {
    case exited(Int32)
    case signaled(Int32)
    case unknown

    init(waitStatus: Int32?) {
        guard let waitStatus else {
            self = .unknown
            return
        }
        let signal = waitStatus & 0x7f
        if signal == 0 {
            self = .exited((waitStatus >> 8) & 0xff)
        } else if signal != 0x7f {
            self = .signaled(signal)
        } else {
            self = .unknown
        }
    }
}

enum TerminalReconnectDecision: Equatable {
    case finished
    case reconnect(after: TimeInterval)
    case serverUpdateRequired
}

/// Decides how a remote pane reacts when its connection process exits.
///
/// The exit codes form a small protocol with the server toolkit's attach command:
/// the shell inside the remote session ended, the client detached while the
/// session lives on, the toolkit is incompatible, or ssh itself failed.
struct TerminalReconnectPolicy: Equatable {
    static let shellExitedCode: Int32 = 0
    static let detachedCode: Int32 = 3
    static let incompatibleCode: Int32 = 4
    static let connectionFailedCode: Int32 = 255

    var initialDelay: TimeInterval = 1
    var maximumDelay: TimeInterval = 30
    var maximumJitter: TimeInterval = 2
    /// A connection that stayed up at least this long resets the backoff.
    var stableConnectionDuration: TimeInterval = 15

    func decision(
        for exit: TerminalProcessExit,
        attempt: Int,
        jitterFraction: Double
    ) -> TerminalReconnectDecision {
        switch exit {
        case .exited(Self.shellExitedCode):
            return .finished
        case .exited(Self.detachedCode):
            // Reattach immediately, unless detaches keep repeating without a stable connection.
            return .reconnect(
                after: attempt <= 1 ? 0 : delay(forAttempt: attempt, jitterFraction: jitterFraction)
            )
        case .exited(Self.incompatibleCode):
            return .serverUpdateRequired
        case .exited(Self.connectionFailedCode), .signaled, .unknown:
            return .reconnect(after: delay(forAttempt: attempt, jitterFraction: jitterFraction))
        case .exited:
            return .finished
        }
    }

    func delay(forAttempt attempt: Int, jitterFraction: Double) -> TimeInterval {
        let exponent = Double(max(0, min(attempt, 16)))
        let base = min(maximumDelay, initialDelay * pow(2, exponent))
        let jitter = maximumJitter * min(max(jitterFraction, 0), 1)
        return min(maximumDelay, base + jitter)
    }

    func nextAttempt(after attempt: Int, connectionDuration: TimeInterval) -> Int {
        connectionDuration >= stableConnectionDuration ? 0 : attempt + 1
    }
}
