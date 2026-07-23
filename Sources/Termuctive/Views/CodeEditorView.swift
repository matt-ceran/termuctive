import AppKit
import SwiftUI

@MainActor
struct CodeEditorView: NSViewRepresentable {
    @ObservedObject var buffer: EditorDocumentBuffer
    let focusHandler: () -> Void
    let saveHandler: () -> Void

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        var isApplyingModelText = false
        var highlightingWorkItem: DispatchWorkItem?

        init(parent: CodeEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingModelText,
                let textView = notification.object as? SourceTextView
            else {
                return
            }
            parent.buffer.updateText(textView.string)
            textView.lineNumberRuler?.rebuildLineStarts()
            if let scrollView = textView.enclosingScrollView {
                textView.updateDocumentGeometry(in: scrollView)
            }
            updateCursor(in: textView)
            scheduleHighlighting(in: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? SourceTextView else {
                return
            }
            updateCursor(in: textView)
        }

        func applyModelTextIfNeeded(to textView: SourceTextView) {
            guard textView.string != parent.buffer.text else {
                return
            }
            isApplyingModelText = true
            let selectionLocation = min(
                textView.selectedRange().location,
                parent.buffer.text.utf16.count
            )
            textView.string = parent.buffer.text
            textView.setSelectedRange(NSRange(location: selectionLocation, length: 0))
            textView.undoManager?.removeAllActions()
            textView.lineNumberRuler?.rebuildLineStarts()
            isApplyingModelText = false
            updateCursor(in: textView)
            applyHighlighting(in: textView)
        }

        func applyHighlighting(in textView: SourceTextView) {
            SourceSyntaxHighlighter.highlight(
                textView: textView,
                fileExtension: parent.buffer.url.pathExtension
            )
        }

        private func scheduleHighlighting(in textView: SourceTextView) {
            highlightingWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else {
                    return
                }
                applyHighlighting(in: textView)
            }
            highlightingWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
        }

        private func updateCursor(in textView: SourceTextView) {
            let location = min(textView.selectedRange().location, textView.string.utf16.count)
            let position =
                textView.lineNumberRuler?.lineAndColumn(at: location)
                ?? SourceLinePosition.resolve(in: textView.string, location: location)
            let buffer = parent.buffer
            Task { @MainActor in
                buffer.updateCursor(line: position.line, column: position.column)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SourceEditorScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let contentSize = scrollView.contentSize
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        let textView = SourceTextView(
            frame: NSRect(origin: .zero, size: contentSize),
            textContainer: textContainer
        )
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor.textColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.insertionPointColor = NSColor.textColor
        textView.drawsBackground = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFindPanel = true
        textView.isIncrementalSearchingEnabled = true
        textView.saveHandler = saveHandler
        textView.focusHandler = focusHandler
        textView.string = buffer.text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier("TermuctiveSourceEditor")

        let lineNumberRuler = SourceLineNumberRulerView(
            scrollView: scrollView,
            orientation: .verticalRuler
        )
        lineNumberRuler.clientView = textView
        textView.lineNumberRuler = lineNumberRuler
        scrollView.verticalRulerView = lineNumberRuler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.documentView = textView
        scrollView.tile()

        lineNumberRuler.rebuildLineStarts()
        textView.updateDocumentGeometry(in: scrollView)
        context.coordinator.applyHighlighting(in: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? SourceTextView else {
            return
        }
        textView.saveHandler = saveHandler
        textView.focusHandler = focusHandler
        context.coordinator.applyModelTextIfNeeded(to: textView)
        textView.updateDocumentGeometry(in: scrollView)
    }
}

final class SourceEditorScrollView: NSScrollView {
    override func layout() {
        super.layout()
        (documentView as? SourceTextView)?.updateDocumentGeometry(in: self)
    }
}

final class SourceTextView: NSTextView {
    weak var lineNumberRuler: SourceLineNumberRulerView?
    var saveHandler: (() -> Void)?
    var focusHandler: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers?.lowercased() == "s"
        {
            saveHandler?()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        focusHandler?()
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            return
        }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else {
                return
            }
            _ = window.makeFirstResponder(self)
        }
    }

    func updateDocumentGeometry(in scrollView: NSScrollView) {
        guard let layoutManager, let textContainer else {
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let viewportSize = scrollView.contentSize
        let targetSize = NSSize(
            width: max(
                viewportSize.width,
                ceil(usedRect.maxX + textContainerInset.width * 2)
            ),
            height: max(
                viewportSize.height,
                ceil(usedRect.maxY + textContainerInset.height * 2)
            )
        )
        if frame.origin != .zero || frame.size != targetSize {
            frame = NSRect(origin: .zero, size: targetSize)
        }
        let visibleOrigin = scrollView.contentView.bounds.origin
        if visibleOrigin.x < 0 || visibleOrigin.y < 0 {
            scrollView.contentView.setBoundsOrigin(
                NSPoint(
                    x: max(visibleOrigin.x, 0),
                    y: max(visibleOrigin.y, 0)
                )
            )
        }
    }
}

final class SourceLineNumberRulerView: NSRulerView {
    private var lineStarts = [0]

    override var isFlipped: Bool {
        true
    }

    func rebuildLineStarts() {
        guard let textView = clientView as? NSTextView else {
            lineStarts = [0]
            return
        }
        let text = textView.string as NSString
        var starts = [0]
        var location = 0
        while location < text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            let nextLocation = NSMaxRange(range)
            guard nextLocation > location else {
                break
            }
            if nextLocation < text.length
                || text.substring(with: range).hasSuffix("\n")
                || text.substring(with: range).hasSuffix("\r")
            {
                starts.append(nextLocation)
            }
            location = nextLocation
        }
        lineStarts = starts
        let digits = max(String(max(starts.count, 1)).count, 2)
        ruleThickness = CGFloat(digits * 8 + 16)
        let requiredTextInset = ruleThickness + 8
        if textView.textContainerInset.width != requiredTextInset {
            textView.textContainerInset.width = requiredTextInset
        }
        needsDisplay = true
    }

    func lineAndColumn(at location: Int) -> (line: Int, column: Int) {
        let clampedLocation = max(location, 0)
        var lowerBound = 0
        var upperBound = lineStarts.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if lineStarts[midpoint] <= clampedLocation {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        let lineIndex = max(lowerBound - 1, 0)
        return (
            line: lineIndex + 1,
            column: clampedLocation - lineStarts[lineIndex] + 1
        )
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer,
            let scrollView
        else {
            return
        }

        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        let visibleRect = scrollView.contentView.bounds
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect,
            in: textContainer
        )
        let characterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange,
            actualGlyphRange: nil
        )
        let firstVisibleLine = lineIndex(containing: characterRange.location)
        let lastCharacter = NSMaxRange(characterRange)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        for lineIndex in firstVisibleLine..<lineStarts.count {
            let characterIndex = lineStarts[lineIndex]
            if characterIndex > lastCharacter {
                break
            }
            let lineRect = lineRect(
                forCharacterAt: characterIndex,
                textLength: textView.string.utf16.count,
                textView: textView,
                layoutManager: layoutManager
            )
            let label = "\(lineIndex + 1)" as NSString
            let labelSize = label.size(withAttributes: attributes)
            let y =
                lineRect.minY
                + textView.textContainerInset.height
                - visibleRect.minY
                + max((lineRect.height - labelSize.height) / 2, 0)
            label.draw(
                at: NSPoint(
                    x: ruleThickness - labelSize.width - 8,
                    y: y
                ),
                withAttributes: attributes
            )
        }

        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
    }

    private func lineRect(
        forCharacterAt characterIndex: Int,
        textLength: Int,
        textView: NSTextView,
        layoutManager: NSLayoutManager
    ) -> NSRect {
        if characterIndex < textLength {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
            return layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil
            )
        }
        guard layoutManager.numberOfGlyphs > 0 else {
            return NSRect(
                x: 0,
                y: 0,
                width: textView.bounds.width,
                height: textView.font?.boundingRectForFont.height ?? 14
            )
        }
        let finalLineRect = layoutManager.lineFragmentRect(
            forGlyphAt: layoutManager.numberOfGlyphs - 1,
            effectiveRange: nil
        )
        return NSRect(
            x: finalLineRect.minX,
            y: finalLineRect.maxY,
            width: finalLineRect.width,
            height: finalLineRect.height
        )
    }

    private func lineIndex(containing location: Int) -> Int {
        var lowerBound = 0
        var upperBound = lineStarts.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if lineStarts[midpoint] <= location {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return max(lowerBound - 1, 0)
    }
}

private enum SourceLinePosition {
    static func resolve(in text: String, location: Int) -> (line: Int, column: Int) {
        let prefix = (text as NSString).substring(
            to: min(max(location, 0), text.utf16.count)
        )
        let lines = prefix.components(separatedBy: .newlines)
        return (line: max(lines.count, 1), column: (lines.last?.utf16.count ?? 0) + 1)
    }
}

private enum SourceSyntaxHighlighter {
    static func highlight(textView: NSTextView, fileExtension: String) {
        guard let layoutManager = textView.layoutManager else {
            return
        }
        let text = textView.string
        let fullRange = NSRange(location: 0, length: text.utf16.count)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        guard fullRange.length <= maximumHighlightedLength else {
            return
        }

        let language = SourceLanguage(fileExtension: fileExtension)
        apply(
            pattern: #"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#,
            color: .systemOrange,
            text: text,
            range: fullRange,
            layoutManager: layoutManager
        )
        if !language.keywords.isEmpty {
            let keywordPattern =
                #"\b(?:"#
                + language.keywords.map(NSRegularExpression.escapedPattern)
                .joined(separator: "|") + #")\b"#
            apply(
                pattern: keywordPattern,
                color: .systemPurple,
                text: text,
                range: fullRange,
                layoutManager: layoutManager
            )
        }
        for pattern in language.stringPatterns {
            apply(
                pattern: pattern,
                color: .systemRed,
                text: text,
                range: fullRange,
                layoutManager: layoutManager
            )
        }
        for pattern in language.commentPatterns {
            apply(
                pattern: pattern,
                color: .systemGreen,
                text: text,
                range: fullRange,
                layoutManager: layoutManager
            )
        }
        if language.isMarkup {
            apply(
                pattern: #"(?m)^\s{0,3}#{1,6}\s+.*$"#,
                color: .systemBlue,
                text: text,
                range: fullRange,
                layoutManager: layoutManager
            )
        }
    }

    private static func apply(
        pattern: String,
        color: NSColor,
        text: String,
        range: NSRange,
        layoutManager: NSLayoutManager
    ) {
        guard
            let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.anchorsMatchLines]
            )
        else {
            return
        }
        expression.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match else {
                return
            }
            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: color,
                forCharacterRange: match.range
            )
        }
    }

    private static let maximumHighlightedLength = 750_000
}

private struct SourceLanguage {
    let keywords: [String]
    let commentPatterns: [String]
    let stringPatterns: [String]
    let isMarkup: Bool

    init(fileExtension: String) {
        let fileExtension = fileExtension.lowercased()
        stringPatterns = [
            #""(?:\\.|[^"\\])*""#,
            #"'(?:\\.|[^'\\])*'"#,
            #"`(?:\\.|[^`\\])*`"#,
        ]

        switch fileExtension {
        case "swift":
            keywords = Self.swiftKeywords
            commentPatterns = Self.cStyleComments
            isMarkup = false
        case "js", "jsx", "mjs", "ts", "tsx":
            keywords = Self.javaScriptKeywords
            commentPatterns = Self.cStyleComments
            isMarkup = false
        case "py", "pyi":
            keywords = Self.pythonKeywords
            commentPatterns = [#"(?m)#.*$"#]
            isMarkup = false
        case "rs":
            keywords = Self.rustKeywords
            commentPatterns = Self.cStyleComments
            isMarkup = false
        case "c", "cc", "cpp", "cs", "h", "hpp", "java", "kt", "kts":
            keywords = Self.cFamilyKeywords
            commentPatterns = Self.cStyleComments
            isMarkup = false
        case "go":
            keywords = Self.goKeywords
            commentPatterns = Self.cStyleComments
            isMarkup = false
        case "bash", "fish", "sh", "zsh":
            keywords = Self.shellKeywords
            commentPatterns = [#"(?m)#.*$"#]
            isMarkup = false
        case "md", "markdown":
            keywords = []
            commentPatterns = [#"(?s)<!--.*?-->"#]
            isMarkup = true
        case "html", "htm", "xml":
            keywords = []
            commentPatterns = [#"(?s)<!--.*?-->"#]
            isMarkup = false
        default:
            keywords = []
            commentPatterns = []
            isMarkup = false
        }
    }

    private static let cStyleComments = [
        #"(?m)//.*$"#,
        #"(?s)/\*.*?\*/"#,
    ]
    private static let swiftKeywords = [
        "actor", "associatedtype", "async", "await", "break", "case", "catch", "class",
        "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
        "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "init", "inout",
        "internal", "is", "let", "nil", "nonisolated", "open", "operator", "private", "protocol",
        "public", "repeat", "rethrows", "return", "self", "some", "static", "struct", "subscript",
        "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while",
    ]
    private static let javaScriptKeywords = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "export", "extends", "false", "finally", "for",
        "from", "function", "get", "if", "implements", "import", "in", "instanceof", "interface",
        "let", "new", "null", "of", "package", "private", "protected", "public", "return", "set",
        "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined",
        "var", "void", "while", "with", "yield",
    ]
    private static let pythonKeywords = [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break", "case",
        "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from",
        "global", "if", "import", "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass",
        "raise", "return", "try", "while", "with", "yield",
    ]
    private static let rustKeywords = [
        "Self", "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
        "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match",
        "mod", "move", "mut", "pub", "ref", "return", "self", "static", "struct", "super",
        "trait", "true", "type", "unsafe", "use", "where", "while",
    ]
    private static let cFamilyKeywords = [
        "abstract", "as", "auto", "bool", "break", "byte", "case", "catch", "char", "class",
        "const", "continue", "default", "delegate", "do", "double", "else", "enum", "explicit",
        "export", "extends", "extern", "false", "final", "finally", "float", "for", "friend",
        "if", "implements", "import", "inline", "int", "interface", "internal", "is", "long",
        "namespace", "new", "null", "operator", "override", "package", "private", "protected",
        "public", "record", "return", "short", "signed", "sizeof", "static", "struct", "super",
        "switch", "template", "this", "throw", "true", "try", "typedef", "typename", "union",
        "unsigned", "using", "virtual", "void", "volatile", "while",
    ]
    private static let goKeywords = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
        "false", "for", "func", "go", "goto", "if", "import", "interface", "map", "nil", "package",
        "range", "return", "select", "struct", "switch", "true", "type", "var",
    ]
    private static let shellKeywords = [
        "case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if",
        "in", "local", "readonly", "return", "select", "then", "time", "until", "while",
    ]
}
