import AppKit
import Foundation
import XCTest

@testable import Termuctive

final class InviteCodeTests: XCTestCase {
    private func sample(expires: Date = Date().addingTimeInterval(3_600)) -> InviteCode {
        InviteCode(
            serverName: "Home Server",
            address: "termuctive.tail1234.ts.net",
            port: 22,
            user: "sam",
            home: "/Users/sam",
            hostKeys: ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA"],
            slug: "bluekite",
            root: "/Users/mattceran/Documents/bluekite",
            projectName: "bluekite",
            owner: "mattceran",
            inviteID: "0123456789abcdef",
            privateKey:
                "-----BEGIN OPENSSH PRIVATE KEY-----\nabc+/=\n-----END OPENSSH PRIVATE KEY-----\n",
            expires: Date(timeIntervalSince1970: (expires.timeIntervalSince1970).rounded())
        )
    }

    func testCodesRoundTripAndSurviveWrappingAndSpaces() throws {
        let code = sample()
        let encoded = try code.encoded()

        XCTAssertTrue(encoded.hasPrefix("tmc1:"))
        XCTAssertFalse(encoded.contains("+") || encoded.contains("/") || encoded.contains("="))
        let wrapped = encoded.enumerated().map { index, character in
            index > 0 && index % 60 == 0 ? "\n  \(character)" : String(character)
        }.joined()
        XCTAssertEqual(try InviteCode.decode(" \(wrapped)\n"), code)
    }

    func testInvalidAndExpiredCodesExplainThemselves() throws {
        XCTAssertThrowsError(try InviteCode.decode("hello")) { error in
            XCTAssertEqual(error as? InviteCodeError, .notAnInvite)
        }
        XCTAssertThrowsError(try InviteCode.decode("tmc1:%%%")) { error in
            XCTAssertEqual(error as? InviteCodeError, .damaged)
        }
        XCTAssertTrue(sample(expires: Date().addingTimeInterval(-1)).isExpired())
        XCTAssertFalse(sample().isExpired())
    }

    func testMemberOnlyHostsHaveNoAdministratorEntry() {
        let host = CloudHost(name: "S", address: "s", adminUser: "", memberUser: "sam")
        let config = SSHConfigRenderer.render(
            hosts: [host],
            paths: SSHPaths(directory: URL(fileURLWithPath: "/Users/n/.termuctive/ssh"))
        )
        XCTAssertTrue(config.contains("Host \(host.alias)\n"))
        XCTAssertFalse(config.contains(host.adminAlias))
    }

    @MainActor
    func testPinningReplacesOnlyThatServersKeys() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("known-\(UUID().uuidString)")
        try "tmc-aaaa ssh-ed25519 OLD\ntmc-bbbb ssh-ed25519 OTHER\n".write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        try CollaborationService.pin(
            hostKeys: ["ssh-ed25519 NEW", "ecdsa-sha2-nistp256 NEW2"],
            alias: "tmc-aaaa",
            knownHosts: url
        )
        XCTAssertEqual(
            try String(contentsOf: url, encoding: .utf8),
            "tmc-bbbb ssh-ed25519 OTHER\ntmc-aaaa ssh-ed25519 NEW\ntmc-aaaa ecdsa-sha2-nistp256 NEW2\n"
        )
    }
}
