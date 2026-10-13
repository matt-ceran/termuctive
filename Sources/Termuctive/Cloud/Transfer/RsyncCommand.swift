import Foundation

/// Builds rsync invocations for macOS's bundled rsync (openrsync), which talks to the
/// server's rsync over Termuctive's private ssh configuration.
struct RsyncCommand: Equatable {
    static let executable = "/usr/bin/rsync"

    let configPath: String
    let alias: String

    /// openrsync splits `-e` on spaces, so the configuration path must not contain any.
    var sshCommand: String {
        "/usr/bin/ssh -F \(configPath) -o BatchMode=yes -o ControlPath=none"
    }

    func arguments(
        source: String,
        destination: String,
        isDirectory: Bool,
        excludes: [String],
        mirrorsDeletions: Bool,
        filesFrom: String? = nil
    ) -> [String] {
        var arguments = ["-rlptz", "--partial", "--progress"]
        if mirrorsDeletions {
            arguments.append("--delete")
        }
        arguments += excludes.map { "--exclude=\($0)" }
        if let filesFrom {
            arguments.append("--files-from=\(filesFrom)")
        }
        arguments += ["-e", sshCommand]
        if isDirectory {
            arguments += [
                Self.directory(source), "\(alias):\(Self.remotePath(Self.directory(destination)))",
            ]
        } else {
            arguments += [source, "\(alias):\(Self.remotePath(destination))"]
        }
        return arguments
    }

    static func directory(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    /// The remote shell splits the destination on whitespace, so unsafe characters are
    /// escaped one by one.
    static func remotePath(_ path: String) -> String {
        let safe = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@%,:="
        )
        var escaped = ""
        for scalar in path.unicodeScalars {
            if !safe.contains(scalar) {
                escaped.append("\\")
            }
            escaped.unicodeScalars.append(scalar)
        }
        return escaped
    }
}

struct RsyncProgress: Equatable {
    var currentFile: String?
    var filesRemaining: Int?
    var filesTotal: Int?
    var completedFileBytes: Int64 = 0

    var fraction: Double? {
        guard let filesRemaining, let filesTotal, filesTotal > 0 else {
            return nil
        }
        return Double(filesTotal - filesRemaining) / Double(filesTotal)
    }
}

/// Reads rsync's `--progress` output, which mixes file names, carriage-return updates
/// and per-file completion lines such as `1,234 100% 1.00MB/s 0:00:01 (xfer#3, to-check=6/10)`.
struct RsyncProgressParser {
    private(set) var progress = RsyncProgress()
    private var buffer = ""

    private static let progressPattern = try? NSRegularExpression(
        pattern: #"^\s*([\d,]+)\s+(\d+)%.*?(?:to-che?c?k=(\d+)/(\d+))?\)?\s*$"#
    )

    mutating func consume(_ text: String) -> RsyncProgress {
        buffer += text
        while let index = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(buffer[..<index])
            buffer.removeSubrange(...index)
            handle(line)
        }
        return progress
    }

    private mutating func handle(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return
        }
        let range = NSRange(line.startIndex..., in: line)
        if let expression = Self.progressPattern,
            let match = expression.firstMatch(in: line, range: range),
            let bytesRange = Range(match.range(at: 1), in: line),
            let percentRange = Range(match.range(at: 2), in: line)
        {
            if line[percentRange] == "100",
                let bytes = Int64(line[bytesRange].replacingOccurrences(of: ",", with: ""))
            {
                progress.completedFileBytes += bytes
            }
            if let remainingRange = Range(match.range(at: 3), in: line),
                let totalRange = Range(match.range(at: 4), in: line)
            {
                progress.filesRemaining = Int(line[remainingRange])
                progress.filesTotal = Int(line[totalRange])
            }
            return
        }
        if Self.isSummary(trimmed) {
            return
        }
        progress.currentFile = trimmed
    }

    private static func isSummary(_ line: String) -> Bool {
        let prefixes = [
            "sending incremental file list", "building file list", "sent ", "total size",
            "receiving", "Transfer starting", "deleting ", "created directory",
        ]
        return prefixes.contains { line.hasPrefix($0) }
    }
}
