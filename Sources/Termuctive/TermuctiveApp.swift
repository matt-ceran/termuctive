import SwiftUI

@main
struct TermuctiveApp: App {
    @StateObject private var store = WorkspaceStore()

    var body: some Scene {
        WindowGroup("Termuctive") {
            WorkspaceView(store: store)
        }
        .defaultSize(width: 1180, height: 740)
        .commands {
            CommandMenu("Pane") {
                Button("Split Right") {
                    store.splitFocusedPane(axis: .horizontal)
                }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(store.focusedPaneID == nil)

                Button("Split Down") {
                    store.splitFocusedPane(axis: .vertical)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(store.focusedPaneID == nil)

                Divider()

                Button("Close Pane") {
                    store.closeFocusedPane()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!store.canCloseFocusedPane)
            }
        }
    }
}
