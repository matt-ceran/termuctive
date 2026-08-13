import AppKit
import XCTest

@testable import Termuctive

@MainActor
final class NoteRichTextTests: XCTestCase {
    func testDarkPaletteUsesDarkCanvasAndAutomaticWhiteText() throws {
        let background = try XCTUnwrap(
            NoteEditorPalette.backgroundColor(for: .dark).usingColorSpace(.deviceRGB)
        )
        let text = try XCTUnwrap(
            NoteEditorPalette.textColor(for: .dark).usingColorSpace(.deviceRGB)
        )
        let automatic = try XCTUnwrap(
            NoteEditorPalette.displayColor(
                for: .black,
                colorScheme: .dark
            ).usingColorSpace(.deviceRGB)
        )
        let explicitRed = try XCTUnwrap(
            NoteEditorPalette.displayColor(
                for: .red,
                colorScheme: .dark
            ).usingColorSpace(.deviceRGB)
        )

        XCTAssertLessThan(background.redComponent, 0.2)
        XCTAssertGreaterThan(text.redComponent, 0.9)
        XCTAssertGreaterThan(automatic.redComponent, 0.9)
        XCTAssertGreaterThan(explicitRed.redComponent, explicitRed.blueComponent)
    }

    func testToolbarLayoutRespondsToPaneWidthAndWorkspaceMode() {
        XCTAssertEqual(NoteToolbarLayout.resolve(width: 1_300, mode: .split), .expanded)
        XCTAssertEqual(NoteToolbarLayout.resolve(width: 900, mode: .split), .regular)
        XCTAssertEqual(NoteToolbarLayout.resolve(width: 520, mode: .split), .compact)
        XCTAssertEqual(NoteToolbarLayout.resolve(width: 320, mode: .split), .narrow)
        XCTAssertEqual(NoteToolbarLayout.resolve(width: 120, mode: .split), .minimal)
        XCTAssertEqual(NoteToolbarLayout.resolve(width: 920, mode: .text), .expanded)
        XCTAssertEqual(NoteToolbarLayout.resolve(width: 820, mode: .text), .regular)
    }

    func testArchiveRoundTripPreservesFontColorAndParagraphStyle() throws {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.paragraphSpacing = 9
        let original = NSAttributedString(
            string: "Conceptual model",
            attributes: [
                .font: try XCTUnwrap(NSFont(name: "Times New Roman", size: 22)),
                .foregroundColor: NSColor.systemBlue,
                .paragraphStyle: paragraphStyle,
            ]
        )

        let data = try NoteRichTextArchive.data(from: original)
        let restored = NoteRichTextArchive.attributedString(from: data)
        let attributes = restored.attributes(at: 0, effectiveRange: nil)
        let font = try XCTUnwrap(attributes[.font] as? NSFont)
        let color = try XCTUnwrap(attributes[.foregroundColor] as? NSColor)
        let rgbColor = try XCTUnwrap(color.usingColorSpace(.deviceRGB))
        let restoredParagraph = try XCTUnwrap(attributes[.paragraphStyle] as? NSParagraphStyle)

        XCTAssertEqual(restored.string, original.string)
        XCTAssertEqual(font.familyName, "Times New Roman")
        XCTAssertEqual(font.pointSize, 22)
        XCTAssertEqual(restoredParagraph.alignment, .center)
        XCTAssertGreaterThan(rgbColor.blueComponent, rgbColor.redComponent)
    }

    func testTitleAndSubheadingStylesApplyToTheCurrentParagraph() throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        textView.isRichText = true
        textView.textStorage?.setAttributedString(
            NSAttributedString(
                string: "Title line\nSubheading line\nBody",
                attributes: NoteRichTextArchive.defaultBodyAttributes
            )
        )
        let controller = NoteRichTextController()
        var changeCount = 0
        controller.attach(to: textView) {
            changeCount += 1
        }

        textView.setSelectedRange(NSRange(location: 2, length: 0))
        controller.applyStyle(.title)
        let titleFont = try XCTUnwrap(
            textView.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        )
        textView.setSelectedRange(NSRange(location: 13, length: 0))
        controller.applyStyle(.subheading)
        let subheadingFont = try XCTUnwrap(
            textView.textStorage?.attribute(.font, at: 13, effectiveRange: nil) as? NSFont
        )

        XCTAssertEqual(titleFont.pointSize, 28)
        XCTAssertTrue(NSFontManager.shared.traits(of: titleFont).contains(.boldFontMask))
        XCTAssertEqual(subheadingFont.pointSize, 17)
        XCTAssertTrue(NSFontManager.shared.traits(of: subheadingFont).contains(.boldFontMask))
        XCTAssertEqual(changeCount, 2)
    }

    func testBodyStyleAppliesToTypingAfterATitleAndReturn() throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        textView.isRichText = true
        let titleFont = NSFontManager.shared.convert(
            NSFont.systemFont(ofSize: 28),
            toHaveTrait: .boldFontMask
        )
        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.paragraphSpacing = 12
        textView.textStorage?.setAttributedString(
            NSAttributedString(
                string: "Title line\n",
                attributes: [
                    .font: titleFont,
                    .foregroundColor: NSColor.black,
                    .paragraphStyle: titleParagraph,
                ]
            )
        )
        textView.typingAttributes = [
            .font: titleFont,
            .foregroundColor: NSColor.black,
            .paragraphStyle: titleParagraph,
        ]
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        let controller = NoteRichTextController()
        controller.attach(to: textView) {}

        controller.applyStyle(.body)

        let retainedTitleFont = try XCTUnwrap(
            textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        let typingFont = try XCTUnwrap(textView.typingAttributes[.font] as? NSFont)
        let typingParagraph = try XCTUnwrap(
            textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle
        )
        XCTAssertEqual(retainedTitleFont.pointSize, 28)
        XCTAssertTrue(NSFontManager.shared.traits(of: retainedTitleFont).contains(.boldFontMask))
        XCTAssertEqual(typingFont.pointSize, 14)
        XCTAssertFalse(NSFontManager.shared.traits(of: typingFont).contains(.boldFontMask))
        XCTAssertEqual(typingParagraph.paragraphSpacing, 5)
        XCTAssertEqual(controller.selectedStyle, .body)
        XCTAssertEqual(controller.fontSize, 14)
    }

    func testTitleAndBodyKeepTheirStylesWhenChangingTheWholeDocumentFont() throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        textView.isRichText = true
        textView.typingAttributes = NoteRichTextArchive.defaultBodyAttributes
        let controller = NoteRichTextController()
        controller.attach(to: textView) {}
        let title = "Project Notes Feature Tour"
        let body = "Project notes autosave rich text."

        controller.applyStyle(.title)
        textView.insertText(title, replacementRange: textView.selectedRange())
        textView.insertNewline(nil)
        controller.applyStyle(.body)
        textView.insertText(body, replacementRange: textView.selectedRange())
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
        controller.setFontFamily("Times New Roman")

        let archived = try NoteRichTextArchive.data(from: textView.attributedString())
        let restored = NoteRichTextArchive.attributedString(from: archived)
        let titleStartFont = try XCTUnwrap(
            restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        let titleEndFont = try XCTUnwrap(
            restored.attribute(.font, at: title.utf16.count - 1, effectiveRange: nil) as? NSFont
        )
        let bodyFont = try XCTUnwrap(
            restored.attribute(.font, at: title.utf16.count + 1, effectiveRange: nil) as? NSFont
        )
        XCTAssertEqual(restored.string, "\(title)\n\(body)")
        for titleFont in [titleStartFont, titleEndFont] {
            XCTAssertEqual(titleFont.familyName, "Times New Roman")
            XCTAssertEqual(titleFont.pointSize, 28)
            XCTAssertTrue(NSFontManager.shared.traits(of: titleFont).contains(.boldFontMask))
        }
        XCTAssertEqual(bodyFont.familyName, "Times New Roman")
        XCTAssertEqual(bodyFont.pointSize, 14)
        XCTAssertFalse(NSFontManager.shared.traits(of: bodyFont).contains(.boldFontMask))
    }

    func testFormattingControllerChangesFontSizeColorAndAlignment() throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        textView.isRichText = true
        textView.textStorage?.setAttributedString(
            NSAttributedString(
                string: "Formatted note",
                attributes: NoteRichTextArchive.defaultBodyAttributes
            )
        )
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
        let controller = NoteRichTextController()
        var changeCount = 0
        controller.attach(to: textView) {
            changeCount += 1
        }

        controller.setFontFamily("Times New Roman")
        controller.setFontSize(18)
        controller.setTextColor(.red)
        controller.setAlignment(.right)
        controller.toggleItalic()

        let attributes = try XCTUnwrap(textView.textStorage?.attributes(at: 0, effectiveRange: nil))
        let font = try XCTUnwrap(attributes[.font] as? NSFont)
        let color = try XCTUnwrap(attributes[.foregroundColor] as? NSColor)
        let paragraph = try XCTUnwrap(attributes[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(font.familyName, "Times New Roman")
        XCTAssertEqual(font.pointSize, 18)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.italicFontMask))
        XCTAssertGreaterThan(color.redComponent, color.blueComponent)
        XCTAssertEqual(paragraph.alignment, .right)
        XCTAssertEqual(changeCount, 5)
    }

    func testSystemFontChoiceUsesAReadableNameAndPreservesTraits() throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        textView.isRichText = true
        textView.textStorage?.setAttributedString(
            NSAttributedString(
                string: "Readable font",
                attributes: [
                    .font: try XCTUnwrap(NSFont(name: "Times New Roman Bold", size: 18)),
                    .foregroundColor: NSColor.black,
                ]
            )
        )
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
        let controller = NoteRichTextController()
        controller.attach(to: textView) {}

        controller.setFontFamily("System")

        let font = try XCTUnwrap(
            textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        XCTAssertEqual(controller.fontFamily, "System")
        XCTAssertTrue(NoteRichTextController.availableFontFamilies.first == "System")
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertEqual(font.pointSize, 18)
    }
}
