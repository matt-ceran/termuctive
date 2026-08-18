import AppKit
import SwiftUI

enum NoteEditorPalette {
    static func appearance(for colorScheme: ColorScheme) -> NSAppearance {
        NSAppearance(
            named: colorScheme == .dark ? .darkAqua : .aqua
        ) ?? NSAppearance(named: .aqua)!
    }

    static func backgroundColor(for colorScheme: ColorScheme) -> NSColor {
        colorScheme == .dark
            ? NSColor(calibratedWhite: 0.105, alpha: 1)
            : NSColor.white
    }

    static func textColor(for colorScheme: ColorScheme) -> NSColor {
        colorScheme == .dark
            ? NSColor(calibratedWhite: 0.94, alpha: 1)
            : NSColor(calibratedWhite: 0.08, alpha: 1)
    }

    static func displayColor(
        for color: NoteRGBAColor,
        colorScheme: ColorScheme
    ) -> NSColor {
        colorScheme == .dark ? textColor(for: colorScheme) : color.nsColor
    }
}

enum NoteTextStyle: String, CaseIterable, Identifiable {
    case title
    case heading
    case subheading
    case body
    case quote
    case caption
    case code

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .title:
            "Title"
        case .heading:
            "Heading"
        case .subheading:
            "Subheading"
        case .body:
            "Body"
        case .quote:
            "Quote"
        case .caption:
            "Caption"
        case .code:
            "Code"
        }
    }

    fileprivate var fontSize: CGFloat {
        switch self {
        case .title:
            28
        case .heading:
            22
        case .subheading:
            17
        case .body, .quote:
            14
        case .caption:
            11
        case .code:
            13
        }
    }

    fileprivate var paragraphSpacing: CGFloat {
        switch self {
        case .title:
            12
        case .heading:
            9
        case .subheading:
            7
        case .body, .quote, .code:
            5
        case .caption:
            3
        }
    }
}

enum NoteTextAlignment: String, CaseIterable, Identifiable {
    case left
    case center
    case right
    case justified

    var id: String {
        rawValue
    }

    var title: String {
        rawValue.capitalized
    }

    var systemImage: String {
        switch self {
        case .left:
            "text.alignleft"
        case .center:
            "text.aligncenter"
        case .right:
            "text.alignright"
        case .justified:
            "text.justify"
        }
    }

    fileprivate var nativeValue: NSTextAlignment {
        switch self {
        case .left:
            .left
        case .center:
            .center
        case .right:
            .right
        case .justified:
            .justified
        }
    }
}

enum NoteRichTextArchive {
    static func attributedString(from data: Data) -> NSAttributedString {
        guard !data.isEmpty,
            let value = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
        else {
            return NSAttributedString(string: "", attributes: defaultBodyAttributes)
        }
        return value
    }

    static func data(from attributedString: NSAttributedString) throws -> Data {
        try attributedString.data(
            from: NSRange(location: 0, length: attributedString.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    static var defaultBodyAttributes: [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2
        paragraphStyle.paragraphSpacing = NoteTextStyle.body.paragraphSpacing
        return [
            .font: NSFont.systemFont(ofSize: NoteTextStyle.body.fontSize),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraphStyle,
        ]
    }
}

@MainActor
final class NoteRichTextController: ObservableObject {
    @Published private(set) var selectedStyle: NoteTextStyle = .body
    @Published private(set) var fontFamily = "System"
    @Published private(set) var fontSize = 14.0
    @Published private(set) var textColor = NoteRGBAColor.black
    @Published private(set) var alignment: NoteTextAlignment = .left
    @Published private(set) var isBold = false
    @Published private(set) var isItalic = false
    @Published private(set) var isUnderlined = false
    @Published private(set) var isStruckThrough = false

    weak var textView: NSTextView?
    private var onContentChange: (() -> Void)?
    private var selectionRefreshTask: Task<Void, Never>?

    static let availableFontFamilies: [String] = {
        let preferred = [
            "System",
            "Times New Roman",
            "Georgia",
            "Helvetica Neue",
            "Avenir Next",
            "Palatino",
            "Baskerville",
            "Menlo",
        ]
        let available = Set(NSFontManager.shared.availableFontFamilies)
        let preferredAvailable = preferred.filter { $0 == "System" || available.contains($0) }
        let remaining = available.subtracting(preferredAvailable).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        return preferredAvailable + remaining
    }()

    func attach(to textView: NSTextView, onContentChange: @escaping () -> Void) {
        let isNewTextView = self.textView !== textView
        self.textView = textView
        self.onContentChange = onContentChange
        if isNewTextView {
            scheduleSelectionStateRefresh()
        }
    }

    func detach(from textView: NSTextView) {
        guard self.textView === textView else {
            return
        }
        selectionRefreshTask?.cancel()
        selectionRefreshTask = nil
        self.textView = nil
        onContentChange = nil
    }

    func applyStyle(_ style: NoteTextStyle) {
        guard let textView else {
            return
        }
        let selectedRange = textView.selectedRange()
        let paragraphRange = paragraphRange(for: selectedRange, in: textView)
        applyParagraphStyle(style, to: paragraphRange, in: textView)
        applyStyleFont(style, to: paragraphRange, in: textView)
        if selectedStyle != style {
            selectedStyle = style
        }
        emitChange()
    }

    func setFontFamily(_ family: String) {
        mutateFonts { font in
            if family == "System" {
                let fontManager = NSFontManager.shared
                var resolvedFont = NSFont.systemFont(ofSize: font.pointSize)
                let traits = fontManager.traits(of: font)
                if traits.contains(.boldFontMask) {
                    resolvedFont = fontManager.convert(resolvedFont, toHaveTrait: .boldFontMask)
                }
                if traits.contains(.italicFontMask) {
                    resolvedFont = fontManager.convert(resolvedFont, toHaveTrait: .italicFontMask)
                }
                return resolvedFont
            }
            let fontManager = NSFontManager.shared
            guard
                var resolvedFont = fontManager.font(
                    withFamily: family,
                    traits: [],
                    weight: 5,
                    size: font.pointSize
                )
            else {
                return font
            }
            let traits = fontManager.traits(of: font)
            if traits.contains(.boldFontMask) {
                resolvedFont = fontManager.convert(resolvedFont, toHaveTrait: .boldFontMask)
            }
            if traits.contains(.italicFontMask) {
                resolvedFont = fontManager.convert(resolvedFont, toHaveTrait: .italicFontMask)
            }
            return resolvedFont
        }
        if fontFamily != family {
            fontFamily = family
        }
    }

    func setFontSize(_ size: Double) {
        let resolvedSize = min(max(size, 8), 96)
        mutateFonts { font in
            NSFont(descriptor: font.fontDescriptor, size: CGFloat(resolvedSize)) ?? font
        }
        if fontSize != resolvedSize {
            fontSize = resolvedSize
        }
    }

    func setTextColor(_ color: NoteRGBAColor) {
        guard let textView else {
            return
        }
        applyAttribute(.foregroundColor, value: color.nsColor, in: textView)
        if textColor != color {
            textColor = color
        }
        emitChange()
    }

    func setAlignment(_ alignment: NoteTextAlignment) {
        guard let textView else {
            return
        }
        let range = paragraphRange(for: textView.selectedRange(), in: textView)
        mutateParagraphs(in: range, textView: textView) { paragraphStyle in
            paragraphStyle.alignment = alignment.nativeValue
        }
        if self.alignment != alignment {
            self.alignment = alignment
        }
        emitChange()
    }

    func toggleBold() {
        toggleTrait(.boldFontMask, isActive: isBold)
    }

    func toggleItalic() {
        toggleTrait(.italicFontMask, isActive: isItalic)
    }

    func toggleUnderline() {
        toggleIntegerAttribute(.underlineStyle, isActive: isUnderlined)
    }

    func toggleStrikethrough() {
        toggleIntegerAttribute(.strikethroughStyle, isActive: isStruckThrough)
    }

    func insertBullet() {
        insertListPrefix("•\t")
    }

    func insertNumberedItem() {
        insertListPrefix("1.\t")
    }

    func undo() {
        textView?.undoManager?.undo()
        emitChange()
    }

    func redo() {
        textView?.undoManager?.redo()
        emitChange()
    }

    var canUndo: Bool {
        textView?.undoManager?.canUndo == true
    }

    var canRedo: Bool {
        textView?.undoManager?.canRedo == true
    }

    func refreshSelectionState() {
        guard let textView else {
            return
        }
        let attributes = effectiveAttributes(in: textView)
        if let font = attributes[.font] as? NSFont {
            let resolvedFamily = displayName(for: font.familyName ?? font.fontName)
            let resolvedSize = Double(font.pointSize)
            let traits = NSFontManager.shared.traits(of: font)
            let resolvedBold = traits.contains(.boldFontMask)
            let resolvedItalic = traits.contains(.italicFontMask)
            let resolvedStyle = inferredStyle(for: font, attributes: attributes)
            if fontFamily != resolvedFamily {
                fontFamily = resolvedFamily
            }
            if fontSize != resolvedSize {
                fontSize = resolvedSize
            }
            if isBold != resolvedBold {
                isBold = resolvedBold
            }
            if isItalic != resolvedItalic {
                isItalic = resolvedItalic
            }
            if selectedStyle != resolvedStyle {
                selectedStyle = resolvedStyle
            }
        }
        if let color = attributes[.foregroundColor] as? NSColor {
            let resolvedColor = NoteRGBAColor(nsColor: color)
            if textColor != resolvedColor {
                textColor = resolvedColor
            }
        }
        let resolvedUnderline = (attributes[.underlineStyle] as? Int ?? 0) != 0
        let resolvedStrikethrough = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
        if isUnderlined != resolvedUnderline {
            isUnderlined = resolvedUnderline
        }
        if isStruckThrough != resolvedStrikethrough {
            isStruckThrough = resolvedStrikethrough
        }
        if let paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle {
            let resolvedAlignment = alignmentValue(for: paragraphStyle.alignment)
            if alignment != resolvedAlignment {
                alignment = resolvedAlignment
            }
        }
    }

    func scheduleSelectionStateRefresh() {
        selectionRefreshTask?.cancel()
        selectionRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000)
            guard let self, !Task.isCancelled else {
                return
            }
            refreshSelectionState()
        }
    }

    private func mutateFonts(_ transform: (NSFont) -> NSFont) {
        guard let textView else {
            return
        }
        let range = textView.selectedRange()
        if range.length == 0 {
            var attributes = textView.typingAttributes
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
            attributes[.font] = transform(font)
            textView.typingAttributes = attributes
        } else if let textStorage = textView.textStorage {
            textStorage.beginEditing()
            textStorage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let font = value as? NSFont ?? NSFont.systemFont(ofSize: 14)
                textStorage.addAttribute(.font, value: transform(font), range: subrange)
            }
            textStorage.endEditing()
        }
        emitChange()
    }

    private func toggleTrait(_ trait: NSFontTraitMask, isActive: Bool) {
        let fontManager = NSFontManager.shared
        mutateFonts { font in
            if isActive {
                return fontManager.convert(font, toNotHaveTrait: trait)
            }
            return fontManager.convert(font, toHaveTrait: trait)
        }
        refreshSelectionState()
    }

    private func toggleIntegerAttribute(
        _ key: NSAttributedString.Key,
        isActive: Bool
    ) {
        guard let textView else {
            return
        }
        applyAttribute(
            key,
            value: isActive ? 0 : NSUnderlineStyle.single.rawValue,
            in: textView
        )
        emitChange()
        refreshSelectionState()
    }

    private func applyAttribute(
        _ key: NSAttributedString.Key,
        value: Any,
        in textView: NSTextView
    ) {
        let range = textView.selectedRange()
        if range.length == 0 {
            var attributes = textView.typingAttributes
            attributes[key] = value
            textView.typingAttributes = attributes
        } else {
            textView.textStorage?.addAttribute(key, value: value, range: range)
        }
    }

    private func applyStyleFont(
        _ style: NoteTextStyle,
        to selectedRange: NSRange,
        in textView: NSTextView
    ) {
        let fontManager = NSFontManager.shared
        let makeFont: (NSFont) -> NSFont = { font in
            let baseFont: NSFont
            if style == .code {
                baseFont = NSFont.monospacedSystemFont(ofSize: style.fontSize, weight: .regular)
            } else {
                baseFont = NSFont(descriptor: font.fontDescriptor, size: style.fontSize) ?? font
            }
            let withoutBold = fontManager.convert(baseFont, toNotHaveTrait: .boldFontMask)
            let regular = fontManager.convert(withoutBold, toNotHaveTrait: .italicFontMask)
            switch style {
            case .title, .heading, .subheading:
                return fontManager.convert(regular, toHaveTrait: .boldFontMask)
            case .quote:
                return fontManager.convert(regular, toHaveTrait: .italicFontMask)
            case .body, .caption, .code:
                return regular
            }
        }

        if selectedRange.length == 0 {
            var attributes = textView.typingAttributes
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
            attributes[.font] = makeFont(font)
            textView.typingAttributes = attributes
        } else if let textStorage = textView.textStorage {
            textStorage.enumerateAttribute(.font, in: selectedRange) { value, range, _ in
                let font = value as? NSFont ?? NSFont.systemFont(ofSize: 14)
                textStorage.addAttribute(.font, value: makeFont(font), range: range)
            }
        }
        let resolvedSize = Double(style.fontSize)
        if fontSize != resolvedSize {
            fontSize = resolvedSize
        }
    }

    private func applyParagraphStyle(
        _ style: NoteTextStyle,
        to range: NSRange,
        in textView: NSTextView
    ) {
        mutateParagraphs(in: range, textView: textView) { paragraphStyle in
            paragraphStyle.lineSpacing = style == .code ? 1 : 2
            paragraphStyle.paragraphSpacing = style.paragraphSpacing
            paragraphStyle.headIndent = style == .quote ? 18 : 0
            paragraphStyle.firstLineHeadIndent = style == .quote ? 18 : 0
        }
    }

    private func mutateParagraphs(
        in range: NSRange,
        textView: NSTextView,
        mutation: (NSMutableParagraphStyle) -> Void
    ) {
        guard let textStorage = textView.textStorage else {
            return
        }
        if range.length == 0 {
            var attributes = textView.typingAttributes
            let paragraphStyle =
                (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy()
                as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            mutation(paragraphStyle)
            attributes[.paragraphStyle] = paragraphStyle
            textView.typingAttributes = attributes
            return
        }
        textStorage.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
            let paragraphStyle =
                (value as? NSParagraphStyle)?.mutableCopy()
                as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            mutation(paragraphStyle)
            textStorage.addAttribute(.paragraphStyle, value: paragraphStyle, range: subrange)
        }
    }

    private func insertListPrefix(_ prefix: String) {
        guard let textView,
            let textStorage = textView.textStorage
        else {
            return
        }
        let selectedRange = textView.selectedRange()
        let paragraphs = paragraphRange(for: selectedRange, in: textView)
        let insertionRange = NSRange(location: paragraphs.location, length: 0)
        guard textView.shouldChangeText(in: insertionRange, replacementString: prefix) else {
            return
        }
        textStorage.replaceCharacters(in: insertionRange, with: prefix)
        textView.setSelectedRange(
            NSRange(
                location: selectedRange.location + prefix.utf16.count,
                length: selectedRange.length
            )
        )
        textView.didChangeText()
        emitChange()
    }

    private func paragraphRange(for range: NSRange, in textView: NSTextView) -> NSRange {
        let string = textView.string as NSString
        guard string.length > 0 else {
            return range
        }
        if isInsertionInTrailingEmptyParagraph(range, string: string) {
            return range
        }
        let location = min(range.location, string.length - 1)
        let safeRange = NSRange(
            location: location, length: min(range.length, string.length - location))
        return string.paragraphRange(for: safeRange)
    }

    private func effectiveAttributes(in textView: NSTextView) -> [NSAttributedString.Key: Any] {
        let stringLength = textView.string.utf16.count
        guard stringLength > 0,
            let textStorage = textView.textStorage
        else {
            return textView.typingAttributes
        }
        let selectedRange = textView.selectedRange()
        if isInsertionInTrailingEmptyParagraph(
            selectedRange,
            string: textView.string as NSString
        ) {
            return textView.typingAttributes
        }
        let location = min(selectedRange.location, stringLength - 1)
        return textStorage.attributes(at: location, effectiveRange: nil)
    }

    private func isInsertionInTrailingEmptyParagraph(
        _ range: NSRange,
        string: NSString
    ) -> Bool {
        guard range.length == 0,
            range.location == string.length,
            string.length > 0
        else {
            return false
        }
        switch string.character(at: string.length - 1) {
        case 0x000A, 0x000D, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }

    private func inferredStyle(
        for font: NSFont,
        attributes: [NSAttributedString.Key: Any]
    ) -> NoteTextStyle {
        let size = font.pointSize
        if size >= 26 {
            return .title
        }
        if size >= 20 {
            return .heading
        }
        if size >= 16 {
            return .subheading
        }
        if size <= 11.5 {
            return .caption
        }
        if font.isFixedPitch {
            return .code
        }
        if let paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle,
            paragraphStyle.headIndent >= 18,
            NSFontManager.shared.traits(of: font).contains(.italicFontMask)
        {
            return .quote
        }
        return .body
    }

    private func alignmentValue(for alignment: NSTextAlignment) -> NoteTextAlignment {
        switch alignment {
        case .center:
            .center
        case .right:
            .right
        case .justified:
            .justified
        default:
            .left
        }
    }

    private func displayName(for fontFamily: String) -> String {
        fontFamily.hasPrefix(".") ? "System" : fontFamily
    }

    private func emitChange() {
        onContentChange?()
        refreshSelectionState()
    }
}

struct NoteRichTextEditorView: NSViewRepresentable {
    let rtfData: Data
    @ObservedObject var controller: NoteRichTextController
    let onFocus: () -> Void
    let requestsFocus: Bool
    let onChange: (Data) -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NoteTextView(frame: .zero)
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.focusHandler = onFocus
        textView.delegate = context.coordinator
        textView.textStorage?.setAttributedString(
            NoteRichTextArchive.attributedString(from: rtfData))
        textView.textStorage?.delegate = context.coordinator
        if rtfData.isEmpty {
            textView.typingAttributes = NoteRichTextArchive.defaultBodyAttributes
        }
        textView.setAccessibilityLabel("Rich text note editor")

        let scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.lastKnownData = rtfData
        controller.attach(to: textView) { [weak coordinator = context.coordinator] in
            coordinator?.publishCurrentContent()
        }
        context.coordinator.applyPalette(
            colorScheme: colorScheme,
            to: textView,
            in: scrollView
        )
        textView.setLogicalFocus(requestsFocus)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NoteTextView else {
            return
        }
        controller.attach(to: textView) { [weak coordinator = context.coordinator] in
            coordinator?.publishCurrentContent()
        }
        textView.focusHandler = onFocus
        textView.setLogicalFocus(requestsFocus)
        context.coordinator.applyPalette(
            colorScheme: colorScheme,
            to: textView,
            in: scrollView
        )
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }
        coordinator.parent.controller.detach(from: textView)
        if textView.textStorage?.delegate === coordinator {
            textView.textStorage?.delegate = nil
        }
        textView.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency NSTextStorageDelegate, NSTextViewDelegate {
        var parent: NoteRichTextEditorView
        weak var textView: NSTextView?
        var lastKnownData = Data()
        private var appliedColorScheme: ColorScheme?

        init(parent: NoteRichTextEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            publishCurrentContent()
        }

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard !editedMask.intersection([.editedAttributes, .editedCharacters]).isEmpty,
                let textView,
                textView.textStorage === textStorage
            else {
                return
            }
            applyTextPalette(
                colorScheme: parent.colorScheme,
                to: textView,
                requestedRange: editedRange
            )
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            parent.controller.scheduleSelectionStateRefresh()
        }

        func publishCurrentContent() {
            guard let attributedString = textView?.attributedString(),
                let data = try? NoteRichTextArchive.data(from: attributedString),
                data != lastKnownData
            else {
                return
            }
            lastKnownData = data
            parent.onChange(data)
        }

        func applyPalette(
            colorScheme: ColorScheme,
            to textView: NSTextView,
            in scrollView: NSScrollView
        ) {
            guard appliedColorScheme != colorScheme else {
                return
            }
            appliedColorScheme = colorScheme
            let appearance = NoteEditorPalette.appearance(for: colorScheme)
            let backgroundColor = NoteEditorPalette.backgroundColor(for: colorScheme)
            let textColor = NoteEditorPalette.textColor(for: colorScheme)
            textView.appearance = appearance
            textView.backgroundColor = backgroundColor
            textView.insertionPointColor = textColor
            scrollView.appearance = appearance
            scrollView.backgroundColor = backgroundColor

            applyTextPalette(
                colorScheme: colorScheme,
                to: textView,
                requestedRange: NSRange(location: 0, length: textView.textStorage?.length ?? 0)
            )
        }

        private func applyTextPalette(
            colorScheme: ColorScheme,
            to textView: NSTextView,
            requestedRange: NSRange
        ) {
            guard let textStorage = textView.textStorage,
                let layoutManager = textView.layoutManager,
                textStorage.length > 0
            else {
                textView.needsDisplay = true
                return
            }
            let range = NSIntersectionRange(
                requestedRange,
                NSRange(location: 0, length: textStorage.length)
            )
            guard range.length > 0 else {
                textView.needsDisplay = true
                return
            }
            layoutManager.removeTemporaryAttribute(
                .foregroundColor,
                forCharacterRange: range
            )
            guard colorScheme == .dark else {
                textView.needsDisplay = true
                return
            }
            let textColor = NoteEditorPalette.textColor(for: colorScheme)
            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: textColor,
                forCharacterRange: range
            )
            textView.needsDisplay = true
        }
    }
}

@MainActor
private final class NoteTextView: NSTextView {
    var focusHandler: (() -> Void)?
    private var hasLogicalFocus = false

    func setLogicalFocus(_ isFocused: Bool) {
        guard hasLogicalFocus != isFocused else {
            return
        }
        hasLogicalFocus = isFocused
        requestFirstResponderIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestFirstResponderIfNeeded()
    }

    override func mouseDown(with event: NSEvent) {
        focusHandler?()
        super.mouseDown(with: event)
    }

    private func requestFirstResponderIfNeeded() {
        guard hasLogicalFocus,
            let window,
            window.firstResponder !== self
        else {
            return
        }
        window.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else {
            return
        }
        let placeholder = "Start writing, or choose a title style from the toolbar."
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        placeholder.draw(
            at: NSPoint(x: textContainerInset.width + 2, y: textContainerInset.height),
            withAttributes: attributes
        )
    }
}
