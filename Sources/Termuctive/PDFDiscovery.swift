import Foundation

struct RecentPDFLocator {
    static func mostRecentPDF(
        in roots: [URL],
        modifiedAfter sessionStart: Date
    ) -> URL? {
        var bestMatch: (url: URL, modifiedAt: Date)?
        var visitedItemCount = 0

        for root in searchRoots(from: roots) {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, _ in true }
                )
            else {
                continue
            }

            while let candidate = enumerator.nextObject() as? URL {
                visitedItemCount += 1
                guard visitedItemCount <= maximumVisitedItems else {
                    return bestMatch?.url
                }

                guard let values = try? candidate.resourceValues(forKeys: resourceKeys) else {
                    continue
                }
                if values.isDirectory == true {
                    if ignoredDirectoryNames.contains(candidate.lastPathComponent) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true,
                    candidate.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame,
                    let modifiedAt = values.contentModificationDate ?? values.creationDate,
                    modifiedAt >= sessionStart
                else {
                    continue
                }

                let standardizedCandidate = candidate.standardizedFileURL
                if let currentBest = bestMatch {
                    if modifiedAt > currentBest.modifiedAt
                        || (modifiedAt == currentBest.modifiedAt
                            && standardizedCandidate.path > currentBest.url.path)
                    {
                        bestMatch = (standardizedCandidate, modifiedAt)
                    }
                } else {
                    bestMatch = (standardizedCandidate, modifiedAt)
                }
            }
        }

        return bestMatch?.url
    }

    private static func searchRoots(from roots: [URL]) -> [URL] {
        let uniqueRoots = Dictionary(
            roots.map { ($0.standardizedFileURL.path, $0.standardizedFileURL) },
            uniquingKeysWith: { first, _ in first }
        ).values

        return uniqueRoots.filter { candidate in
            !uniqueRoots.contains { other in
                other != candidate
                    && candidate.path.hasPrefix(other.path + "/")
            }
        }
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .contentModificationDateKey,
        .creationDateKey,
        .isDirectoryKey,
        .isRegularFileKey,
    ]
    private static let ignoredDirectoryNames: Set<String> = [
        ".build",
        ".git",
        ".swiftpm",
        "DerivedData",
        "node_modules",
    ]
    private static let maximumVisitedItems = 100_000
}

struct TerminalOutputPDFTracker {
    private var rollingOutput = ""
    private var reportedPaths: Set<String> = []

    mutating func consume(
        _ bytes: ArraySlice<UInt8>,
        workingDirectory: String
    ) -> [URL] {
        guard let chunk = String(bytes: bytes, encoding: .utf8), !chunk.isEmpty else {
            return []
        }

        rollingOutput += Self.removingANSISequences(from: chunk)
        if rollingOutput.count > Self.maximumOutputCharacters {
            rollingOutput.removeFirst(rollingOutput.count - Self.maximumOutputCharacters)
        }

        var matches: [URL] = []
        for expression in Self.pathExpressions {
            let range = NSRange(rollingOutput.startIndex..., in: rollingOutput)
            for match in expression.matches(in: rollingOutput, range: range) {
                guard let matchRange = Range(match.range, in: rollingOutput),
                    let url = Self.resolve(
                        String(rollingOutput[matchRange]),
                        workingDirectory: workingDirectory
                    ),
                    !reportedPaths.contains(url.path)
                else {
                    continue
                }
                reportedPaths.insert(url.path)
                matches.append(url)
            }
        }
        return matches
    }

    private static func resolve(
        _ candidate: String,
        workingDirectory: String
    ) -> URL? {
        let decoded = candidate.removingPercentEncoding ?? candidate
        let url: URL
        if decoded.hasPrefix("file://") {
            guard let fileURL = URL(string: decoded), fileURL.isFileURL else {
                return nil
            }
            url = fileURL
        } else if decoded.hasPrefix("~/") {
            url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(decoded.dropFirst(2)))
        } else if decoded.hasPrefix("/") {
            url = URL(fileURLWithPath: decoded)
        } else {
            url = URL(fileURLWithPath: workingDirectory, isDirectory: true)
                .appendingPathComponent(decoded)
        }

        let standardizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard standardizedURL.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame,
            FileManager.default.fileExists(
                atPath: standardizedURL.path,
                isDirectory: &isDirectory
            ),
            !isDirectory.boolValue
        else {
            return nil
        }
        return standardizedURL
    }

    private static func removingANSISequences(from string: String) -> String {
        guard let ansiExpression else {
            return string
        }
        let range = NSRange(string.startIndex..., in: string)
        return ansiExpression.stringByReplacingMatches(
            in: string,
            range: range,
            withTemplate: ""
        )
    }

    private static let pathExpressions: [NSRegularExpression] = [
        #"(?:file://)?(?:~|/)[^\s\]\[<>\"']*?\.pdf"#,
        #"(?:\.{1,2}/|[A-Za-z0-9_.%+()-]+/)[A-Za-z0-9_./%+()\-]*?\.pdf"#,
        #"[A-Za-z0-9_.%+()\-]+\.pdf"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    private static let ansiExpression = try? NSRegularExpression(
        pattern: #"\u{001B}\[[0-?]*[ -/]*[@-~]"#
    )
    private static let maximumOutputCharacters = 32_768
}
