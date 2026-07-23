import SwiftUI

@main
struct TermuctiveApp: App {
    @NSApplicationDelegateAdaptor(TermuctiveApplicationDelegate.self)
    private var applicationDelegate

    @StateObject private var store: WorkspaceStore
    @StateObject private var sessions: TerminalSessionPool
    @StateObject private var editors: EditorSessionPool
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
        _editors = StateObject(wrappedValue: EditorSessionPool(store: store))
        _appearance = StateObject(wrappedValue: appearance)
    }

    var body: some Scene {
        Window("Termuctive", id: "main") {
            WorkspaceView(
                store: store,
                sessions: sessions,
                editors: editors,
                appearance: appearance
            )
            .preferredColorScheme(appearance.appTheme.colorScheme)
            .onAppear {
                applicationDelegate.editorSessions = editors
            }
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
                    setSidebarVisible(!store.isSidebarVisible)
                }
                .keyboardShortcut("0", modifiers: [.command])
            }

            CommandMenu("Pane") {
                Button(
                    isFocusedPaneEditorPresented
                        ? "Return Focused Pane to Terminal"
                        : "Open IDE in Focused Pane"
                ) {
                    toggleFocusedPaneEditor()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(store.focusedPaneID == nil)

                Divider()

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

                Button("Open Recent PDF in Opposite Pane") {
                    moveRecentPDF(.automatic)
                }
                .disabled(store.focusedPaneID == nil)

                Button("Open Recent PDF on Left") {
                    moveRecentPDF(.left)
                }
                .disabled(store.focusedPaneID == nil)

                Button("Open Recent PDF on Right") {
                    moveRecentPDF(.right)
                }
                .disabled(store.focusedPaneID == nil)

                Divider()

                Button("Close Pane") {
                    guard let focusedPaneID = store.focusedPaneID else {
                        return
                    }
                    editors.requestClosePane(withID: focusedPaneID)
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

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    saveFocusedEditorFile()
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(!canSaveFocusedEditorFile)
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

    private func moveRecentPDF(_ placement: PDFPanePlacement) {
        guard let focusedPaneID = store.focusedPaneID else {
            return
        }
        sessions.moveRecentPDF(
            fromPaneID: focusedPaneID,
            placement: placement
        )
    }

    private var isFocusedPaneEditorPresented: Bool {
        guard let focusedPaneID = store.focusedPaneID else {
            return false
        }
        return editors.isEditorPresented(inPaneID: focusedPaneID)
    }

    private var canSaveFocusedEditorFile: Bool {
        guard let focusedPaneID = store.focusedPaneID,
            let buffer = editors.session(forPaneID: focusedPaneID)?.selectedBuffer
        else {
            return false
        }
        return buffer.canSave
    }

    private func toggleFocusedPaneEditor() {
        guard let focusedPaneID = store.focusedPaneID else {
            return
        }
        if editors.isEditorPresented(inPaneID: focusedPaneID) {
            editors.dismissEditor(inPaneID: focusedPaneID)
            sessions.focus(paneID: focusedPaneID)
        } else {
            sessions.dismissPDFPreview(inPaneID: focusedPaneID)
            editors.presentEditor(inPaneID: focusedPaneID)
        }
    }

    private func saveFocusedEditorFile() {
        guard let focusedPaneID = store.focusedPaneID,
            let session = editors.session(forPaneID: focusedPaneID)
        else {
            return
        }
        Task {
            await session.saveSelectedBuffer()
        }
    }

    private func setSidebarVisible(_ isVisible: Bool) {
        guard store.isSidebarVisible != isVisible else {
            return
        }
        sessions.prepareForAnimatedLayoutTransition(
            duration: SidebarMotion.panelDuration
        )
        withAnimation(SidebarMotion.panel) {
            store.isSidebarVisible = isVisible
        }
    }
}
