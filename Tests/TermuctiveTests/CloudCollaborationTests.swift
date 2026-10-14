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

    func testInviteFilesRoundTripAndOnlyTheirOwnerCanRead() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let url = try sample().writeFile(in: directory)

        XCTAssertEqual(url.lastPathComponent, "Join bluekite.termuctive-invite")
        let permissions =
            try FileManager.default.attributesOfItem(atPath: url.path)[
                .posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertEqual(try InviteCode.decode(InviteCode.text(ofFileAt: url)), sample())

        let large = directory.appendingPathComponent("large.termuctive-invite")
        try Data(repeating: 65, count: 100_000).write(to: large)
        XCTAssertThrowsError(try InviteCode.text(ofFileAt: large)) { error in
            XCTAssertEqual(error as? InviteCodeError, .notAnInvite)
        }
    }

    @MainActor
    func testOpeningAnInviteFileShowsTheJoinSheetOnceTheWorkspaceIsReady() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = try sample().writeFile(in: directory)
        let delegate = TermuctiveApplicationDelegate()
        let store = WorkspaceStore(persistence: CollaborationTestWorkspacePersistence())
        let (cloud, _) = makeTestCloud(store: store)

        delegate.application(NSApplication.shared, open: [url])
        XCTAssertNil(cloud.presentedFlow)
        delegate.cloud = cloud

        XCTAssertEqual(cloud.presentedFlow, .joinProject)
        XCTAssertEqual(try InviteCode.decode(try XCTUnwrap(cloud.pendingInviteText)), sample())
    }

    @MainActor
    func testJoinSetupSignsInAndCarriesTheGitIdentity() {
        let command = CollaborationService.joinSetupCommand(
            user: "sam",
            gitIdentity: GitIdentity(name: "Sam O'Neil", email: "sam@example.com")
        )

        XCTAssertTrue(
            command.hasPrefix("sudo -n /opt/termuctive/bin/tmc admin install-claude --user sam; ")
        )
        XCTAssertTrue(
            command.contains(
                "git config --global user.name >/dev/null || "
                    + "git config --global user.name 'Sam O'\\''Neil'"))
        XCTAssertTrue(command.contains("git config --global user.email sam@example.com"))
        XCTAssertTrue(command.contains("gh auth status >/dev/null 2>&1 || {"))
        XCTAssertTrue(command.hasSuffix("; claude"))
        XCTAssertFalse(
            CollaborationService.joinSetupCommand(user: "sam", gitIdentity: nil)
                .contains("git config"))
    }

    @MainActor
    func testOnlyConnectionFailuresAskForTailscale() {
        func result(_ status: Int32, _ message: String, timedOut: Bool = false) -> ProcessResult {
            ProcessResult(
                status: status, output: Data(), error: Data(message.utf8), timedOut: timedOut)
        }

        XCTAssertTrue(
            CollaborationService.serverIsUnreachable(
                result(255, "ssh: Could not resolve hostname home.tail1234.ts.net: nodename"))
        )
        XCTAssertTrue(
            CollaborationService.serverIsUnreachable(
                result(255, "ssh: connect to host 100.1.2.3 port 22: Operation timed out"))
        )
        XCTAssertFalse(
            CollaborationService.serverIsUnreachable(result(255, "Permission denied (publickey)."))
        )
        XCTAssertFalse(CollaborationService.serverIsUnreachable(result(1, "timed out")))
        XCTAssertFalse(
            CollaborationService.serverIsUnreachable(result(255, "timed out", timedOut: true))
        )
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

private final class CollaborationTestWorkspacePersistence: WorkspacePersisting {
    func load() throws -> WorkspaceDocument? {
        nil
    }

    func save(_ document: WorkspaceDocument) throws {}
}
