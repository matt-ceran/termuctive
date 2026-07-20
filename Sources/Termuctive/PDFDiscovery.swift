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
    private var rollingBytes: [UInt8] = []
    private var reportedPaths: Set<String> = []

    mutating func consume(
        _ bytes: ArraySlice<UInt8>,
        workingDirectory: String
    ) -> [URL] {
        guard !bytes.isEmpty else {
            return []
        }

        let firstNewExtensionStart = max(0, rollingBytes.count - 3)
        rollingBytes.append(contentsOf: bytes)

        var matches: [URL] = []
        for extensionEnd in Self.pdfExtensionEndOffsets(
            in: rollingBytes,
            startingAt: firstNewExtensionStart
        ) {
            let candidateStart = max(0, extensionEnd - Self.maximumCandidateBytes)
            let candidateOutput = String(
                decoding: rollingBytes[candidateStart..<extensionEnd],
                as: UTF8.self
            )
            guard
                let url = Self.detectedURLAtEnd(
                    in: candidateOutput,
                    workingDirectory: workingDirectory
                )
            else {
                continue
            }
            guard reportedPaths.insert(url.path).inserted else {
                continue
            }
            matches.append(url)
        }

        if rollingBytes.count > Self.maximumBufferedBytes {
            rollingBytes.removeFirst(rollingBytes.count - Self.retainedOutputBytes)
        }
        return matches
    }

    static func detectedURLs(
        in output: String,
        workingDirectory: String
    ) -> [URL] {
        let visibleOutput = removingANSISequences(from: output)
        let searchRange = NSRange(visibleOutput.startIndex..., in: visibleOutput)
        var candidates: [(range: NSRange, value: String)] = []

        for expression in pathExpressions {
            for match in expression.matches(in: visibleOutput, range: searchRange) {
                guard let range = Range(match.range, in: visibleOutput) else {
                    continue
                }
                candidates.append((match.range, String(visibleOutput[range])))
            }
        }
        candidates.sort {
            if $0.range.location == $1.range.location {
                return $0.range.length > $1.range.length
            }
            return $0.range.location < $1.range.location
        }

        var acceptedRanges: [NSRange] = []
        var urls: [URL] = []
        for candidate in candidates {
            guard !acceptedRanges.contains(where: { rangeContains($0, candidate.range) }) else {
                continue
            }
            guard let url = resolve(candidate.value, workingDirectory: workingDirectory) else {
                continue
            }
            acceptedRanges.append(candidate.range)
            urls.removeAll { $0 == url }
            urls.append(url)
        }
        return urls
    }

    private static func detectedURLAtEnd(
        in output: String,
        workingDirectory: String
    ) -> URL? {
        let visibleOutput = removingANSISequences(from: output)
        guard
            let extensionRange = visibleOutput.range(
                of: ".pdf",
                options: [.caseInsensitive, .backwards]
            )
        else {
            return nil
        }

        let prefix = visibleOutput[..<extensionRange.upperBound]
        let tokenStart =
            prefix.lastIndex(where: { $0.isWhitespace }).map {
                prefix.index(after: $0)
            } ?? prefix.startIndex
        let token = String(prefix[tokenStart...])
        let searchRange = NSRange(token.startIndex..., in: token)
        var candidates: [String] = []
        for expression in pathExpressions {
            for match in expression.matches(in: token, range: searchRange) {
                guard NSMaxRange(match.range) == searchRange.length,
                    let range = Range(match.range, in: token)
                else {
                    continue
                }
                candidates.append(String(token[range]))
            }
        }
        candidates.sort { $0.utf16.count > $1.utf16.count }

        for candidate in candidates {
            if let url = resolve(candidate, workingDirectory: workingDirectory) {
                return url
            }
        }
        return nil
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
        var result = string
        for expression in terminalControlExpressions {
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: ""
            )
        }
        return result
    }

    private static func rangeContains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        outer.location <= inner.location
            && NSMaxRange(outer) >= NSMaxRange(inner)
    }

    private static func pdfExtensionEndOffsets(
        in bytes: [UInt8],
        startingAt proposedStart: Int
    ) -> [Int] {
        guard bytes.count >= 4 else {
            return []
        }

        let finalStart = bytes.count - 4
        let start = min(max(proposedStart, 0), finalStart)
        var offsets: [Int] = []
        for index in start...finalStart {
            guard bytes[index] == 0x2E,
                lowercasedASCII(bytes[index + 1]) == 0x70,
                lowercasedASCII(bytes[index + 2]) == 0x64,
                lowercasedASCII(bytes[index + 3]) == 0x66
            else {
                continue
            }
            offsets.append(index + 4)
        }
        return offsets
    }

    private static func lowercasedASCII(_ byte: UInt8) -> UInt8 {
        guard byte >= 0x41, byte <= 0x5A else {
            return byte
        }
        return byte + 0x20
    }

    private static let pathExpressions: [NSRegularExpression] = [
        #"(?:file://)?(?:~|/)[^\s\]\[<>\"']*?\.pdf"#,
        #"(?:\.{1,2}/|[A-Za-z0-9_.%+()-]+/)[A-Za-z0-9_./%+()\-]*?\.pdf"#,
        #"[A-Za-z0-9_.%+()\-]+\.pdf"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    private static let terminalControlExpressions: [NSRegularExpression] = [
        "\u{001B}\\[[0-?]*[ -/]*[@-~]",
        "\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)",
    ].compactMap { try? NSRegularExpression(pattern: $0) }
    private static let maximumCandidateBytes = 4_096
    private static let retainedOutputBytes = maximumCandidateBytes
    private static let maximumBufferedBytes = retainedOutputBytes * 2
}
