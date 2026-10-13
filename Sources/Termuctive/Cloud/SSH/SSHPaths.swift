import Foundation

/// Termuctive's private SSH material, kept apart from the user's own ~/.ssh setup.
struct SSHPaths: Equatable {
    /// macOS limits UNIX socket paths to 104 bytes, and ssh appends a temporary suffix
    /// to control socket paths while creating them.
    static let maximumSocketPathLength = 104
    static let controlSocketNameLength = 40
    static let temporarySuffixLength = 17

    let directory: URL
    let controlDirectory: URL

    init(directory: URL, controlDirectory: URL? = nil) {
        self.directory = directory
        self.controlDirectory =
            controlDirectory ?? Self.preferredControlDirectory(inside: directory)
    }

    static var live: SSHPaths {
        SSHPaths(
            directory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".termuctive", isDirectory: true)
                .appendingPathComponent("ssh", isDirectory: true)
        )
    }

    var configURL: URL {
        directory.appendingPathComponent("config")
    }

    var knownHostsURL: URL {
        directory.appendingPathComponent("known_hosts")
    }

    var memberKeyURL: URL {
        directory.appendingPathComponent("id_ed25519")
    }

    var adminKeyURL: URL {
        directory.appendingPathComponent("admin_ed25519")
    }

    var controlPathTemplate: String {
        controlDirectory.path + "/%C"
    }

    var longestControlSocketPath: Int {
        controlDirectory.path.utf8.count + 1 + Self.controlSocketNameLength
            + Self.temporarySuffixLength
    }

    func prepareDirectories() throws {
        for url in [directory, controlDirectory] {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
        }
    }

    private static func preferredControlDirectory(inside directory: URL) -> URL {
        let candidate = directory.appendingPathComponent("cm", isDirectory: true)
        let length =
            candidate.path.utf8.count + 1 + controlSocketNameLength + temporarySuffixLength
        if length < maximumSocketPathLength, !candidate.path.contains(" ") {
            return candidate
        }
        return URL(fileURLWithPath: "/tmp/termuctive-\(getuid())", isDirectory: true)
            .appendingPathComponent("cm", isDirectory: true)
    }
}
