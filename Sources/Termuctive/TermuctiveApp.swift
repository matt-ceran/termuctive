import SwiftUI

@main
struct TermuctiveApp: App {
    @StateObject private var store: WorkspaceStore
    @StateObject private var sessions: TerminalSessionPool
    @StateObject private var appearance: AppearanceSettings

    @MainActor
    init() {
        let store = WorkspaceStore()
        let appearance = AppearanceSettings()
        _store = StateObject(wrappedValue: store)
        _sessions = StateObject(
            wrappedValue: TerminalSessionPool(
                store: store,
                terminalTheme: appearance.terminalTheme
            )
        )
        _appearance = StateObject(wrappedValue: appearance)
    }

    var body: some Scene {
        Window("Termuctive", id: "main") {
            WorkspaceView(
                store: store,
                sessions: sessions,
                appearance: appearance
            )
            .preferredColorScheme(appearance.appTheme.colorScheme)
            .onChange(of: appearance.terminalTheme) { _, theme in
                sessions.setTerminalTheme(theme)
            }
        }
        .defaultSize(width: 1180, height: 740)
        .commands {
            CommandMenu("Workspace") {
                Button("Previous Project") {
                    store.selectPreviousProject()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                .disabled(!store.canCycleProjects)

                Button("Next Project") {
                    store.selectNextProject()
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                .disabled(!store.canCycleProjects)

                Divider()

                Button("Previous Terminal Space") {
                    store.selectPreviousSpace()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!store.canCycleSpaces)

                Button("Next Terminal Space") {
                    store.selectNextSpace()
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!store.canCycleSpaces)

                Divider()

                Button(store.isSidebarVisible ? "Hide Projects" : "Show Projects") {
                    store.isSidebarVisible.toggle()
                }
                .keyboardShortcut("0", modifiers: [.command])
            }

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

                Divider()

                Button("Focus Previous Pane") {
                    store.focusPreviousPane()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!store.canCyclePanes)

                Button("Focus Next Pane") {
                    store.focusNextPane()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!store.canCyclePanes)

                Divider()

                Button(store.isFocusedPaneZoomed ? "Show All Panes" : "Zoom Focused Pane") {
                    store.toggleFocusedPaneZoom()
                    if let focusedPaneID = store.focusedPaneID {
                        sessions.focus(paneID: focusedPaneID)
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(!store.canZoomFocusedPane)

                Divider()

                Button("Increase Font Size") {
                    sessions.increaseFontSize()
                }
                .keyboardShortcut("+", modifiers: [.command])
                .disabled(!sessions.canIncreaseFontSize)

                Button("Decrease Font Size") {
                    sessions.decreaseFontSize()
                }
                .keyboardShortcut("-", modifiers: [.command])
                .disabled(!sessions.canDecreaseFontSize)
            }

            CommandMenu("Appearance") {
                Picker("App Appearance", selection: $appearance.appTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }

                Divider()

                Picker("Terminal Appearance", selection: $appearance.terminalTheme) {
                    ForEach(TerminalTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
            }
        }

        Settings {
            AppearanceSettingsView(settings: appearance)
                .preferredColorScheme(appearance.appTheme.colorScheme)
        }
    }
}
