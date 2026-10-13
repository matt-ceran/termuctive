import Foundation

enum SSHKeyError: LocalizedError {
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .generationFailed(let detail):
            "Termuctive could not create its SSH key. \(detail)"
        }
    }
}

enum SSHKeyManager {
    /// Returns the public key at `url`, creating the key pair first when needed.
    static func ensureKey(at url: URL, comment: String) async throws -> String {
        let publicURL = url.appendingPathExtension("pub")
        if FileManager.default.fileExists(atPath: url.path),
            let existing = try? String(contentsOf: publicURL, encoding: .utf8)
        {
            return existing.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: publicURL)
        let result = try await ProcessRunner.run(
            "/usr/bin/ssh-keygen",
            ["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", url.path]
        )
        guard result.succeeded,
            let publicKey = try? String(contentsOf: publicURL, encoding: .utf8)
        else {
            throw SSHKeyError.generationFailed(result.errorText)
        }
        return publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func comment(for role: String) -> String {
        let user = NSUserName().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }
            .joined()
        return "termuctive-\(role)-\(user)"
    }
}
