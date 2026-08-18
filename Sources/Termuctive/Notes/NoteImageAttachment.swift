import AppKit
import UniformTypeIdentifiers

enum NoteImageLayout {
    static let minimumWidth: CGFloat = 48
    static let maximumDefaultWidth: CGFloat = 640

    static func fittedSize(
        for imageSize: NSSize,
        maximumWidth: CGFloat
    ) -> NSSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return NSSize(width: minimumWidth, height: minimumWidth)
        }
        let widthLimit = max(minimumWidth, maximumWidth)
        let scale = min(1, widthLimit / imageSize.width)
        return NSSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
    }

    static func resizedSize(
        from originalSize: NSSize,
        horizontalDelta: CGFloat,
        verticalDelta: CGFloat,
        maximumWidth: CGFloat
    ) -> NSSize {
        guard originalSize.width > 0, originalSize.height > 0 else {
            return NSSize(width: minimumWidth, height: minimumWidth)
        }
        let aspectRatio = originalSize.width / originalSize.height
        let widthDelta =
            abs(horizontalDelta) >= abs(verticalDelta)
            ? horizontalDelta
            : verticalDelta * aspectRatio
        let width = min(
            max(originalSize.width + widthDelta, minimumWidth),
            max(minimumWidth, maximumWidth)
        )
        return NSSize(width: width, height: width / aspectRatio)
    }
}

enum NoteImageAttachmentStorage {
    private static let filenamePrefix = "termuctive-image-v1-"
    private static let storedUnitScale = 1_000.0

    static func makeFileWrapper(
        data: Data,
        contentType: String,
        size: NSSize
    ) -> FileWrapper {
        let wrapper = FileWrapper(regularFileWithContents: data)
        let fileExtension =
            UTType(contentType)?.preferredFilenameExtension
            ?? UTType.png.preferredFilenameExtension
            ?? "png"
        wrapper.preferredFilename = filename(
            id: UUID(),
            size: size,
            fileExtension: fileExtension
        )
        return wrapper
    }

    static func image(for attachment: NSTextAttachment) -> NSImage? {
        if let image = attachment.image {
            return image
        }
        if let contents = attachment.contents,
            let image = NSImage(data: contents)
        {
            return image
        }
        if let contents = attachment.fileWrapper?.regularFileContents {
            return NSImage(data: contents)
        }
        return nil
    }

    static func storedSize(for attachment: NSTextAttachment) -> NSSize? {
        guard
            let name = attachment.fileWrapper?.preferredFilename
                ?? attachment.fileWrapper?.filename,
            name.hasPrefix(filenamePrefix)
        else {
            return nil
        }
        let payload = String(name.dropFirst(filenamePrefix.count))
        guard payload.count > 38 else {
            return nil
        }
        let idEnd = payload.index(payload.startIndex, offsetBy: 36)
        guard UUID(uuidString: String(payload[..<idEnd])) != nil,
            payload[idEnd] == "-"
        else {
            return nil
        }
        let dimensionsAndExtension = payload[payload.index(after: idEnd)...]
        let dimensions = dimensionsAndExtension.split(separator: ".", maxSplits: 1).first?
            .split(separator: "-", maxSplits: 1)
        guard let dimensions,
            dimensions.count == 2,
            let storedWidth = Double(dimensions[0]),
            let storedHeight = Double(dimensions[1]),
            storedWidth > 0,
            storedHeight > 0
        else {
            return nil
        }
        return NSSize(
            width: storedWidth / storedUnitScale,
            height: storedHeight / storedUnitScale
        )
    }

    static func replacement(
        for attachment: NSTextAttachment,
        size: NSSize
    ) -> NSTextAttachment? {
        let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents
        guard let data else {
            return nil
        }
        let existingName =
            attachment.fileWrapper?.preferredFilename
            ?? attachment.fileWrapper?.filename
            ?? "image.png"
        let fileExtension =
            URL(fileURLWithPath: existingName).pathExtension.isEmpty
            ? "png"
            : URL(fileURLWithPath: existingName).pathExtension
        let contentType =
            UTType(filenameExtension: fileExtension)?.identifier
            ?? UTType.png.identifier
        let wrapper = makeFileWrapper(
            data: data,
            contentType: contentType,
            size: size
        )
        let replacement = NSTextAttachment(fileWrapper: wrapper)
        replacement.bounds = NSRect(origin: attachment.bounds.origin, size: size)
        replacement.lineLayoutPadding = attachment.lineLayoutPadding
        return replacement
    }

    static func restoreMetadata(in attributedString: NSAttributedString) {
        let range = NSRange(location: 0, length: attributedString.length)
        attributedString.enumerateAttribute(.attachment, in: range) { value, _, _ in
            guard let attachment = value as? NSTextAttachment,
                let size = storedSize(for: attachment)
            else {
                return
            }
            attachment.bounds.size = size
        }
    }

    private static func filename(
        id: UUID,
        size: NSSize,
        fileExtension: String
    ) -> String {
        let width = Int((size.width * storedUnitScale).rounded())
        let height = Int((size.height * storedUnitScale).rounded())
        return "\(filenamePrefix)\(id.uuidString)-\(width)-\(height).\(fileExtension)"
    }
}

struct NoteImageDragPreview {
    let image: NSImage
    let imageRect: NSRect
    let insertionRect: NSRect
}

extension NoteRichTextController {
    func chooseAndInsertImage() {
        guard let textView, let window = textView.window else {
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose an image to insert at the text cursor."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            Task { @MainActor [weak self] in
                _ = self?.insertImage(at: url)
            }
        }
    }

    @discardableResult
    func insertImage(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
            let image = NSImage(data: data)
        else {
            return false
        }
        let contentType =
            (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.identifier
            ?? UTType.data.identifier
        return insertImage(image, data: data, contentType: contentType)
    }

    @discardableResult
    func insertImage(
        _ image: NSImage,
        data: Data? = nil,
        contentType: String = UTType.png.identifier
    ) -> Bool {
        guard let textView = textView as? NoteTextView else {
            return false
        }
        return textView.insertInlineImage(
            image,
            data: data ?? image.notePNGData,
            contentType: contentType
        )
    }
}

extension NSImage {
    fileprivate var notePNGData: Data? {
        guard let tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffRepresentation)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}

@MainActor
final class NoteImageAttachmentCell: NSTextAttachmentCell {
    private static let handleSize: CGFloat = 12

    override func cellSize() -> NSSize {
        guard let attachment, attachment.bounds.size.width > 0 else {
            return super.cellSize()
        }
        return attachment.bounds.size
    }

    override func draw(
        withFrame cellFrame: NSRect,
        in controlView: NSView?,
        characterIndex: Int,
        layoutManager: NSLayoutManager
    ) {
        if let attachment,
            let image = NoteImageAttachmentStorage.image(for: attachment)
        {
            image.draw(
                in: cellFrame,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        } else {
            super.draw(
                withFrame: cellFrame,
                in: controlView,
                characterIndex: characterIndex,
                layoutManager: layoutManager
            )
        }
        guard let textView = controlView as? NSTextView,
            NSLocationInRange(characterIndex, textView.selectedRange())
        else {
            return
        }

        NSGraphicsContext.saveGraphicsState()
        let border = NSBezierPath(rect: cellFrame.insetBy(dx: 0.75, dy: 0.75))
        border.lineWidth = 1.5
        NSColor.controlAccentColor.setStroke()
        border.stroke()

        let handle = Self.resizeHandleFrame(in: cellFrame)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(ovalIn: handle).fill()
        let handleBorder = NSBezierPath(ovalIn: handle.insetBy(dx: 0.75, dy: 0.75))
        handleBorder.lineWidth = 1.5
        NSColor.controlAccentColor.setStroke()
        handleBorder.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func wantsToTrackMouse(
        for event: NSEvent,
        in cellFrame: NSRect,
        of controlView: NSView?,
        atCharacterIndex charIndex: Int
    ) -> Bool {
        true
    }

    override func trackMouse(
        with event: NSEvent,
        in cellFrame: NSRect,
        of controlView: NSView?,
        atCharacterIndex charIndex: Int,
        untilMouseUp flag: Bool
    ) -> Bool {
        guard let textView = controlView as? NoteTextView else {
            return super.trackMouse(
                with: event,
                in: cellFrame,
                of: controlView,
                atCharacterIndex: charIndex,
                untilMouseUp: flag
            )
        }
        let point = textView.convert(event.locationInWindow, from: nil)
        guard Self.resizeHandleFrame(in: cellFrame).insetBy(dx: -3, dy: -3).contains(point) else {
            return super.trackMouse(
                with: event,
                in: cellFrame,
                of: controlView,
                atCharacterIndex: charIndex,
                untilMouseUp: flag
            )
        }
        return textView.trackImageAttachmentResize(
            at: charIndex,
            from: cellFrame.size,
            mouseDownEvent: event
        )
    }

    private static func resizeHandleFrame(in cellFrame: NSRect) -> NSRect {
        NSRect(
            x: cellFrame.maxX - handleSize / 2,
            y: cellFrame.maxY - handleSize / 2,
            width: handleSize,
            height: handleSize
        )
    }
}

extension NoteTextView {
    var maximumInlineImageWidth: CGFloat {
        let insetWidth = textContainerInset.width * 2
        let viewWidth = max(bounds.width - insetWidth, NoteImageLayout.minimumWidth)
        let containerWidth = textContainer?.containerSize.width ?? 0
        let resolvedWidth =
            containerWidth.isFinite && containerWidth > 0
            ? min(viewWidth, containerWidth)
            : viewWidth
        return min(resolvedWidth, NoteImageLayout.maximumDefaultWidth)
    }

    @discardableResult
    func insertInlineImage(
        _ image: NSImage,
        data: Data?,
        contentType: String
    ) -> Bool {
        guard let data else {
            return false
        }
        let fittedSize = NoteImageLayout.fittedSize(
            for: image.size,
            maximumWidth: maximumInlineImageWidth
        )
        let wrapper = NoteImageAttachmentStorage.makeFileWrapper(
            data: data,
            contentType: contentType,
            size: fittedSize
        )
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        attachment.bounds = NSRect(origin: .zero, size: fittedSize)
        attachment.lineLayoutPadding = 3
        installImageCell(on: attachment, image: image)

        let selectedRange = selectedRange()
        let replacement = NSMutableAttributedString(attachment: attachment)
        var inheritedAttributes = typingAttributes
        inheritedAttributes.removeValue(forKey: .attachment)
        replacement.addAttributes(
            inheritedAttributes,
            range: NSRange(location: 0, length: replacement.length)
        )
        insertText(replacement, replacementRange: selectedRange)
        prepareInlineImages(in: NSRange(location: selectedRange.location, length: 1))
        setSelectedRange(NSRange(location: selectedRange.location, length: 1))
        return true
    }

    func prepareInlineImages(in requestedRange: NSRange? = nil) {
        guard !isPreparingInlineImages,
            let textStorage,
            textStorage.length > 0
        else {
            return
        }
        isPreparingInlineImages = true
        defer { isPreparingInlineImages = false }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        let range = requestedRange.map { NSIntersectionRange($0, fullRange) } ?? fullRange
        guard range.length > 0 else {
            return
        }

        var updates:
            [(range: NSRange, attachment: NSTextAttachment, image: NSImage, size: NSSize)] = []
        textStorage.enumerateAttribute(.attachment, in: range) { value, range, _ in
            guard let attachment = value as? NSTextAttachment,
                let image = NoteImageAttachmentStorage.image(for: attachment)
            else {
                return
            }
            let currentSize = attachment.bounds.size
            let sourceSize =
                currentSize.width > 0 && currentSize.height > 0
                ? currentSize
                : NoteImageAttachmentStorage.storedSize(for: attachment) ?? image.size
            let fittedSize = NoteImageLayout.fittedSize(
                for: sourceSize,
                maximumWidth: maximumInlineImageWidth
            )
            updates.append((range, attachment, image, fittedSize))
        }
        for update in updates {
            let attachment: NSTextAttachment
            if NoteImageAttachmentStorage.storedSize(for: update.attachment) == nil,
                let replacement = NoteImageAttachmentStorage.replacement(
                    for: update.attachment,
                    size: update.size
                )
            {
                attachment = replacement
                textStorage.addAttribute(
                    .attachment,
                    value: replacement,
                    range: update.range
                )
            } else {
                attachment = update.attachment
                attachment.bounds.size = update.size
            }
            attachment.lineLayoutPadding = 3
            installImageCell(on: attachment, image: update.image)
            layoutManager?.invalidateLayout(
                forCharacterRange: update.range,
                actualCharacterRange: nil
            )
            layoutManager?.invalidateDisplay(forCharacterRange: update.range)
        }
    }

    @discardableResult
    func moveImageAttachment(from sourceIndex: Int, to requestedIndex: Int) -> Int? {
        guard let textStorage,
            sourceIndex >= 0,
            sourceIndex < textStorage.length,
            textStorage.attribute(.attachment, at: sourceIndex, effectiveRange: nil)
                is NSTextAttachment
        else {
            return nil
        }
        let sourceRange = NSRange(location: sourceIndex, length: 1)
        let attachmentString = textStorage.attributedSubstring(from: sourceRange)
        let boundedRequest = min(max(requestedIndex, 0), textStorage.length)
        var destinationIndex = boundedRequest
        if destinationIndex > sourceIndex {
            destinationIndex -= 1
        }
        destinationIndex = min(max(destinationIndex, 0), textStorage.length - 1)
        guard destinationIndex != sourceIndex else {
            setSelectedRange(sourceRange)
            return sourceIndex
        }
        guard shouldChangeText(in: sourceRange, replacementString: nil) else {
            return nil
        }

        textStorage.beginEditing()
        textStorage.deleteCharacters(in: sourceRange)
        textStorage.insert(attachmentString, at: destinationIndex)
        textStorage.endEditing()
        didChangeText()
        setSelectedRange(NSRange(location: destinationIndex, length: 1))
        let undoDestination = sourceIndex > destinationIndex ? sourceIndex + 1 : sourceIndex
        undoManager?.registerUndo(withTarget: self) { textView in
            _ = textView.moveImageAttachment(
                from: destinationIndex,
                to: undoDestination
            )
        }
        return destinationIndex
    }

    @discardableResult
    func resizeImageAttachment(at characterIndex: Int, to size: NSSize) -> Bool {
        guard let attachment = imageAttachment(at: characterIndex) else {
            return false
        }
        let previousSize = attachment.bounds.size
        let resolvedSize = NoteImageLayout.resizedSize(
            from: previousSize,
            horizontalDelta: size.width - previousSize.width,
            verticalDelta: size.height - previousSize.height,
            maximumWidth: maximumInlineImageWidth
        )
        guard previousSize != resolvedSize else {
            return false
        }
        applyImageAttachmentSize(resolvedSize, at: characterIndex)
        didChangeText()
        undoManager?.registerUndo(withTarget: self) { textView in
            _ = textView.resizeImageAttachment(at: characterIndex, to: previousSize)
        }
        return true
    }

    func trackImageAttachmentResize(
        at characterIndex: Int,
        from originalSize: NSSize,
        mouseDownEvent: NSEvent
    ) -> Bool {
        guard let window, imageAttachment(at: characterIndex) != nil else {
            return false
        }
        let startingPoint = convert(mouseDownEvent.locationInWindow, from: nil)
        var finalSize = originalSize
        var didResize = false
        NSCursor.resizeLeftRight.push()
        defer { NSCursor.pop() }

        while let event = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            let point = convert(event.locationInWindow, from: nil)
            finalSize = NoteImageLayout.resizedSize(
                from: originalSize,
                horizontalDelta: point.x - startingPoint.x,
                verticalDelta: point.y - startingPoint.y,
                maximumWidth: maximumInlineImageWidth
            )
            if finalSize != originalSize {
                didResize = true
                applyImageAttachmentSize(
                    finalSize,
                    at: characterIndex,
                    recordsMetadata: false
                )
            }
            if event.type == .leftMouseUp {
                break
            }
        }

        guard didResize else {
            return true
        }
        applyImageAttachmentSize(finalSize, at: characterIndex)
        setSelectedRange(NSRange(location: characterIndex, length: 1))
        didChangeText()
        undoManager?.registerUndo(withTarget: self) { textView in
            _ = textView.resizeImageAttachment(at: characterIndex, to: originalSize)
        }
        return true
    }

    func trackImageAttachmentMove(
        at characterIndex: Int,
        in cellFrame: NSRect,
        event initialEvent: NSEvent
    ) {
        guard let window,
            let attachment = imageAttachment(at: characterIndex),
            let image = NoteImageAttachmentStorage.image(for: attachment)
        else {
            return
        }
        let startingPoint = convert(initialEvent.locationInWindow, from: nil)
        var destinationIndex = characterIndex
        var didDrag = false
        NSCursor.closedHand.push()
        defer {
            NSCursor.pop()
            imageDragPreview = nil
            needsDisplay = true
        }

        while let event = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            let point = convert(event.locationInWindow, from: nil)
            let distance = hypot(point.x - startingPoint.x, point.y - startingPoint.y)
            didDrag = didDrag || distance >= 3
            if didDrag {
                destinationIndex = insertionCharacterIndex(at: point)
                imageDragPreview = NoteImageDragPreview(
                    image: image,
                    imageRect: NSRect(
                        x: point.x - cellFrame.width / 2,
                        y: point.y - cellFrame.height / 2,
                        width: cellFrame.width,
                        height: cellFrame.height
                    ),
                    insertionRect: NSRect(
                        x: point.x - 1,
                        y: point.y - 14,
                        width: 2,
                        height: 28
                    )
                )
                needsDisplay = true
            }
            if event.type == .leftMouseUp {
                break
            }
        }

        if didDrag {
            _ = moveImageAttachment(from: characterIndex, to: destinationIndex)
        } else {
            setSelectedRange(NSRange(location: characterIndex, length: 1))
        }
    }

    func drawImageDragPreview() {
        guard let imageDragPreview else {
            return
        }
        imageDragPreview.image.draw(
            in: imageDragPreview.imageRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 0.62,
            respectFlipped: true,
            hints: nil
        )
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: imageDragPreview.insertionRect, xRadius: 1, yRadius: 1).fill()
    }

    private func installImageCell(
        on attachment: NSTextAttachment,
        image: NSImage? = nil
    ) {
        guard !(attachment.attachmentCell is NoteImageAttachmentCell) else {
            return
        }
        let cell = NoteImageAttachmentCell(
            imageCell: image ?? NoteImageAttachmentStorage.image(for: attachment)
        )
        cell.attachment = attachment
        attachment.attachmentCell = cell
    }

    private func imageAttachment(at characterIndex: Int) -> NSTextAttachment? {
        guard let textStorage,
            characterIndex >= 0,
            characterIndex < textStorage.length
        else {
            return nil
        }
        return textStorage.attribute(
            .attachment,
            at: characterIndex,
            effectiveRange: nil
        ) as? NSTextAttachment
    }

    private func applyImageAttachmentSize(
        _ size: NSSize,
        at characterIndex: Int,
        recordsMetadata: Bool = true
    ) {
        guard let attachment = imageAttachment(at: characterIndex) else {
            return
        }
        if recordsMetadata {
            guard let image = NoteImageAttachmentStorage.image(for: attachment),
                let replacement = NoteImageAttachmentStorage.replacement(
                    for: attachment,
                    size: size
                ),
                let textStorage
            else {
                return
            }
            installImageCell(on: replacement, image: image)
            textStorage.addAttribute(
                .attachment,
                value: replacement,
                range: NSRange(location: characterIndex, length: 1)
            )
        } else {
            attachment.bounds.size = size
        }
        let range = NSRange(location: characterIndex, length: 1)
        layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        layoutManager?.invalidateDisplay(forCharacterRange: range)
        needsDisplay = true
    }

    private func insertionCharacterIndex(at point: NSPoint) -> Int {
        guard let layoutManager, let textContainer, let textStorage else {
            return selectedRange().location
        }
        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else {
            return textStorage.length
        }
        let glyphRange = NSRange(location: glyphIndex, length: 1)
        let characterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange,
            actualGlyphRange: nil
        )
        let index = fraction > 0.5 ? NSMaxRange(characterRange) : characterRange.location
        return min(max(index, 0), textStorage.length)
    }
}
