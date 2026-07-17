import Foundation

enum PDFPanePlacement: Equatable {
    case automatic
    case left
    case right
}

enum TerminalLocalCommand: Equatable {
    case moveRecentPDF(PDFPanePlacement)

    init?(line: String) {
        switch line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "/movepdf":
            self = .moveRecentPDF(.automatic)
        case "/movepdfleft":
            self = .moveRecentPDF(.left)
        case "/movepdfright":
            self = .moveRecentPDF(.right)
        default:
            return nil
        }
    }
}

enum TerminalControlInput: Equatable {
    case submit(enhanced: Bool)
    case backspace
    case resetLine
    case invalidateLine
    case enhancedRelease(keyCode: Int)
    case other

    init(bytes: ArraySlice<UInt8>) {
        switch Array(bytes) {
        case [0x0D], [0x0A], [0x0D, 0x0A]:
            self = .submit(enhanced: false)
        case [0x08], [0x7F]:
            self = .backspace
        case [0x03], [0x15]:
            self = .resetLine
        default:
            if bytes.count == 1, let byte = bytes.first, byte < 0x20 {
                self = .invalidateLine
            } else if Self.isLegacyNavigation(bytes) {
                self = .invalidateLine
            } else {
                self = Self.enhancedInput(bytes) ?? .other
            }
        }
    }

    private static func isLegacyNavigation(_ bytes: ArraySlice<UInt8>) -> Bool {
        let data = Array(bytes)
        guard data.count >= 3, data[0] == 0x1B else {
            return false
        }
        if data[1] == 0x4F {
            return true
        }
        guard data[1] == 0x5B, let terminator = data.last else {
            return false
        }
        return [0x41, 0x42, 0x43, 0x44, 0x46, 0x48, 0x5A, 0x7E].contains(terminator)
    }

    private static func enhancedInput(_ bytes: ArraySlice<UInt8>) -> Self? {
        let data = Array(bytes)
        guard data.count >= 5, data.starts(with: [0x1B, 0x5B]), data.last == 0x75,
            let body = String(bytes: data.dropFirst(2).dropLast(), encoding: .ascii)
        else {
            return nil
        }

        let parameters = body.split(separator: ";", omittingEmptySubsequences: false)
        guard let keyParameter = parameters.first?.split(separator: ":").first,
            let keyCode = Int(keyParameter)
        else {
            return nil
        }

        let modifierParts = parameters.count > 1 ? parameters[1].split(separator: ":") : []
        if modifierParts.count > 1, Int(modifierParts[1]) == 3 {
            return .enhancedRelease(keyCode: keyCode)
        }
        if keyCode == 13 {
            return .submit(enhanced: true)
        }
        if keyCode == 127 {
            return .backspace
        }

        guard let encodedModifiers = modifierParts.first.flatMap({ Int($0) }) else {
            return .other
        }
        let modifiers = max(0, encodedModifiers - 1)
        if modifiers & 0x04 != 0, keyCode == 99 || keyCode == 117 {
            return .resetLine
        }
        return .invalidateLine
    }
}

struct TerminalLocalCommandTracker {
    private var currentLine = ""
    private var canRecognizeCurrentLine = true

    mutating func insert(_ text: String) {
        guard canRecognizeCurrentLine else {
            return
        }
        guard text.unicodeScalars.allSatisfy(Self.isPrintable) else {
            invalidate()
            return
        }

        currentLine.append(text)
        if currentLine.utf8.count > Self.maximumCommandLength {
            invalidate()
        }
    }

    mutating func deleteBackward() {
        guard canRecognizeCurrentLine, !currentLine.isEmpty else {
            return
        }
        currentLine.removeLast()
    }

    mutating func commandForSubmission() -> TerminalLocalCommand? {
        defer { reset() }
        guard canRecognizeCurrentLine else {
            return nil
        }
        return TerminalLocalCommand(line: currentLine)
    }

    mutating func invalidate() {
        currentLine.removeAll(keepingCapacity: true)
        canRecognizeCurrentLine = false
    }

    mutating func reset() {
        currentLine.removeAll(keepingCapacity: true)
        canRecognizeCurrentLine = true
    }

    private static func isPrintable(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 0x20 && scalar.value != 0x7F
    }

    private static let maximumCommandLength = 64
}
