import Foundation

/// Everything a collaborator's Termuctive needs to join a cloud project, as one string.
///
/// The code carries a one-time key that the server only accepts for registering the
/// collaborator's own key, and the server's host keys so the first connection cannot be
/// intercepted. It expires after two days.
struct InviteCode: Codable, Equatable {
    static let prefix = "tmc1:"

    var version = 1
    var serverName: String
    var address: String
    var port: Int
    var user: String
    var home: String
    var hostKeys: [String]
    var slug: String
    var root: String
    var projectName: String
    var owner: String
    var inviteID: String
    var privateKey: String
    var expires: Date

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let base64 = try encoder.encode(self).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self.prefix + base64
    }

    static func decode(_ text: String) throws -> InviteCode {
        let trimmed = text.components(separatedBy: .whitespacesAndNewlines).joined()
        guard trimmed.hasPrefix(prefix) else {
            throw InviteCodeError.notAnInvite
        }
        var base64 = String(trimmed.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64) else {
            throw InviteCodeError.damaged
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let code: InviteCode
        do {
            code = try decoder.decode(InviteCode.self, from: data)
        } catch {
            throw InviteCodeError.damaged
        }
        guard code.version == 1 else {
            throw InviteCodeError.unsupportedVersion
        }
        return code
    }

    func isExpired(at date: Date = Date()) -> Bool {
        date >= expires
    }
}

enum InviteCodeError: LocalizedError, Equatable {
    case notAnInvite
    case damaged
    case unsupportedVersion
    case expired

    var errorDescription: String? {
        switch self {
        case .notAnInvite:
            "That is not a Termuctive invite code. It starts with tmc1:."
        case .damaged:
            "The invite code is incomplete. Copy the whole code again."
        case .unsupportedVersion:
            "This invite needs a newer version of Termuctive."
        case .expired:
            "This invite has expired. Ask for a new one."
        }
    }
}
