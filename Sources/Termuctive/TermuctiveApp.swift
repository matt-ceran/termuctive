import SwiftUI

@main
struct TermuctiveApp: App {
    @StateObject private var store: WorkspaceStore
    @StateObject private var sessions: TerminalSessionPool

    @MainActor
    init() {
        let store = WorkspaceStore()
        _store = StateObject(wrappedValue: store)
        _sessions = StateObject(wrappedValue: TerminalSessionPool(store: store))
    }

    var body: some Scene {
        Window("Termuctive", id: "main") {
            WorkspaceView(store: store, sessions: sessions)
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
