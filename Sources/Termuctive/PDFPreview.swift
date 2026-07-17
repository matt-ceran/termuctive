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

struct TerminalInputDecision: Equatable {
    var bytesToForward: [UInt8] = []
    var shouldClearCurrentLine = false
    var command: TerminalLocalCommand?
}

struct TerminalLocalCommandInterceptor {
    private var currentLine: [UInt8] = []
    private var canRecognizeCurrentLine = true
    private var suppressNextLineFeed = false

    mutating func process(_ data: ArraySlice<UInt8>) -> TerminalInputDecision {
        var decision = TerminalInputDecision()

        for byte in data {
            if suppressNextLineFeed {
                suppressNextLineFeed = false
                if byte == Self.lineFeed {
                    continue
                }
            }

            switch byte {
            case Self.carriageReturn, Self.lineFeed:
                if canRecognizeCurrentLine,
                    let line = String(bytes: currentLine, encoding: .utf8),
                    let command = TerminalLocalCommand(line: line)
                {
                    decision.shouldClearCurrentLine = true
                    decision.command = command
                    suppressNextLineFeed = byte == Self.carriageReturn
                } else {
                    decision.bytesToForward.append(byte)
                }
                resetLine()

            case Self.backspace, Self.delete:
                decision.bytesToForward.append(byte)
                if canRecognizeCurrentLine, !currentLine.isEmpty {
                    currentLine.removeLast()
                }

            case Self.cancel, Self.clearLine:
                decision.bytesToForward.append(byte)
                resetLine()

            case 0x20...0x7E:
                decision.bytesToForward.append(byte)
                guard canRecognizeCurrentLine else {
                    continue
                }
                currentLine.append(byte)
                if currentLine.count > Self.maximumCommandLength {
                    canRecognizeCurrentLine = false
                }

            default:
                decision.bytesToForward.append(byte)
                canRecognizeCurrentLine = false
            }
        }

        return decision
    }

    private mutating func resetLine() {
        currentLine.removeAll(keepingCapacity: true)
        canRecognizeCurrentLine = true
    }

    private static let carriageReturn: UInt8 = 0x0D
    private static let lineFeed: UInt8 = 0x0A
    private static let backspace: UInt8 = 0x08
    private static let delete: UInt8 = 0x7F
    private static let cancel: UInt8 = 0x03
    private static let clearLine: UInt8 = 0x15
    private static let maximumCommandLength = 64
}
