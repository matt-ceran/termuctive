import PDFKit
import SwiftUI

struct PDFPaneView: NSViewRepresentable {
    let url: URL
    let focusHandler: () -> Void

    final class Coordinator {
        var loadedURL: URL?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> FocusablePDFView {
        let view = FocusablePDFView(frame: .zero)
        view.focusHandler = focusHandler
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = .windowBackgroundColor
        loadDocument(in: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: FocusablePDFView, context: Context) {
        view.focusHandler = focusHandler
        guard context.coordinator.loadedURL != url else {
            return
        }
        loadDocument(in: view, coordinator: context.coordinator)
    }

    private func loadDocument(
        in view: PDFView,
        coordinator: Coordinator
    ) {
        view.document = PDFDocument(url: url)
        view.autoScales = true
        coordinator.loadedURL = url
    }
}

final class FocusablePDFView: PDFView {
    var focusHandler: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        focusHandler?()
        super.mouseDown(with: event)
    }
}
