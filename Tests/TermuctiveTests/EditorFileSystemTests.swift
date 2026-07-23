import Foundation
import XCTest

@testable import Termuctive

final class EditorFileSystemTests: XCTestCase {
    func testProjectTreeSortsDirectoriesFirstAndSkipsGeneratedDependencies() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try createFile(at: directory.appendingPathComponent("README.md"))
        try createFile(at: directory.appendingPathComponent("Sources/App.swift"))
        try createFile(at: directory.appendingPathComponent(".github/workflows/tests.yml"))
        try createFile(at: directory.appendingPathComponent(".git/config"))
        try createFile(at: directory.appendingPathComponent("node_modules/pkg/index.js"))

        let tree = try EditorFileTreeBuilder.build(rootURL: directory)

        XCTAssertEqual(tree.nodes.map(\.name), [".github", "Sources", "README.md"])
        XCTAssertTrue(treeContains(tree.nodes, pathSuffix: "Sources/App.swift"))
        XCTAssertTrue(treeContains(tree.nodes, pathSuffix: ".github/workflows/tests.yml"))
        XCTAssertFalse(treeContains(tree.nodes, pathSuffix: ".git/config"))
        XCTAssertFalse(treeContains(tree.nodes, pathSuffix: "node_modules/pkg/index.js"))
        XCTAssertFalse(tree.isTruncated)
    }

    func testProjectTreeReportsWhenItsSafetyLimitIsReached() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try createFile(at: directory.appendingPathComponent("a.swift"))
        try createFile(at: directory.appendingPathComponent("b.swift"))
        try createFile(at: directory.appendingPathComponent("c.swift"))

        let tree = try EditorFileTreeBuilder.build(
            rootURL: directory,
            maximumItemCount: 2
        )

        XCTAssertEqual(tree.nodes.count, 2)
        XCTAssertTrue(tree.isTruncated)
    }

    private func treeContains(_ nodes: [EditorFileNode], pathSuffix: String) -> Bool {
        nodes.contains { node in
            node.url.path.hasSuffix(pathSuffix)
                || treeContains(node.children, pathSuffix: pathSuffix)
        }
    }

    private func createFile(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("test\n".utf8).write(to: url)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "termuctive-editor-tree-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
