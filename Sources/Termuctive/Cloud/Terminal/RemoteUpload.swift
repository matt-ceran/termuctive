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
