import AppKit
import Foundation

/// Copies pasted images and dropped files to a server so programs there, such as
/// Claude Code, can open them by path.
enum RemoteUpload {
    struct Item: Equatable {
        let name: String
        let data: Data
    }

    /// Larger files are left alone; they belong in the project instead.
    static let maximumSize = 50 * 1024 * 1024

    static func items(from pasteboard: NSPasteboard) -> [Item]? {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return urls.compactMap { url in
                guard
                    let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                    size <= maximumSize,
                    let data = try? Data(contentsOf: url)
                else {
                    return nil
                }
                return Item(name: url.lastPathComponent, data: data)
            }
        }
        if let image = NSImage(pasteboard: pasteboard),
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        {
            return [Item(name: "pasted-image.png", data: png)]
        }
        return nil
    }

    /// Uploads each item under a unique name and returns the server paths.
    static func upload(_ items: [Item], to target: RemoteUploadTarget) async -> [String] {
        var paths: [String] = []
        for item in items {
            let name = uniqueName(for: item.name)
            let path = target.directory + "/" + name
            let script =
                "mkdir -p \(ShellQuoting.quote(target.directory)) && cat > \(ShellQuoting.quote(path))"
            let result = try? await ProcessRunner.run(
                "/usr/bin/ssh",
                [
                    "-F", target.sshConfigPath, "-T", "-o", "BatchMode=yes",
                    target.alias, "--", script,
                ],
                input: item.data,
                timeout: 120
            )
            if result?.succeeded == true {
                paths.append(path)
            }
        }
        return paths
    }

    static func uniqueName(for name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let cleaned = String(
            name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        )
        let stamp = UUID().uuidString.prefix(8).lowercased()
        return "\(stamp)-\(cleaned.isEmpty ? "file" : cleaned)"
    }
}

/// Fetches files from a server for panes that show them on this Mac, such as PDFs.
enum RemoteDownload {
    static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Termuctive", isDirectory: true)
            .appendingPathComponent("cloud", isDirectory: true)
    }

    /// Copies `path` from the server into the cache, keeping its folder structure.
    static func download(_ path: String, from target: RemoteUploadTarget) async -> URL? {
        let result = try? await ProcessRunner.run(
            "/usr/bin/ssh",
            [
                "-F", target.sshConfigPath, "-T", "-o", "BatchMode=yes", target.alias, "--",
                "cat " + ShellQuoting.quote(path),
            ],
            timeout: 300
        )
        guard let result, result.succeeded, !result.output.isEmpty else {
            return nil
        }
        let base = cacheDirectory.appendingPathComponent(target.alias, isDirectory: true)
            .standardizedFileURL
        let destination = base.appendingPathComponent(String(path.drop(while: { $0 == "/" })))
            .standardizedFileURL
        // Paths come from terminal output, so never write outside the cache.
        guard destination.path.hasPrefix(base.path + "/") else {
            return nil
        }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try result.output.write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
    }

    /// The newest PDF under `root` on the server changed after `since`.
    static func newestPDF(
        under root: String,
        since: Date,
        on target: RemoteUploadTarget
    ) async -> String? {
        let result = try? await ProcessRunner.run(
            "/usr/bin/ssh",
            [
                "-F", target.sshConfigPath, "-T", "-o", "BatchMode=yes", target.alias, "--",
                ShellQuoting.command([
                    TMCClient.executable, "fs", "recent-pdf", "--root", root,
                    "--since", String(since.timeIntervalSince1970),
                ]),
            ],
            timeout: 60
        )
        guard let result, result.succeeded,
            let object = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any]
        else {
            return nil
        }
        return object["path"] as? String
    }
}
