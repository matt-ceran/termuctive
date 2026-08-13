import SwiftUI

@main
struct TermuctiveApp: App {
    @NSApplicationDelegateAdaptor(TermuctiveApplicationDelegate.self)
    private var applicationDelegate

    @StateObject private var store: WorkspaceStore
    @StateObject private var sessions: TerminalSessionPool
    @StateObject private var editors: EditorSessionPool
    @StateObject private var notes: NoteSessionPool
    @StateObject private var appearance: AppearanceSettings
    @StateObject private var agentActivity: AgentActivityRegistry

    @MainActor
    init() {
        let store = WorkspaceStore()
        let appearance = AppearanceSettings()
        let agentActivity = AgentActivityRegistry()
        _store = StateObject(wrappedValue: store)
        _sessions = StateObject(
            wrappedValue: TerminalSessionPool(
                store: store,
                terminalTheme: appearance.terminalTheme,
                agentActivityRegistry: agentActivity
            )
        )
        _editors = StateObject(wrappedValue: EditorSessionPool(store: store))
        _notes = StateObject(wrappedValue: NoteSessionPool())
        _appearance = StateObject(wrappedValue: appearance)
        _agentActivity = StateObject(wrappedValue: agentActivity)
    }

    var body: some Scene {
        Window("Termuctive", id: "main") {
            WorkspaceView(
                store: store,
                sessions: sessions,
                editors: editors,
                notes: notes,
                appearance: appearance,
                agentActivity: agentActivity
            )
            .preferredColorScheme(appearance.appTheme.colorScheme)
            .onAppear {
                applicationDelegate.workspaceStore = store
                applicationDelegate.editorSessions = editors
                applicationDelegate.noteSessions = notes
            }
            .onChange(of: appearance.terminalTheme) { _, theme in
                sessions.setTerminalTheme(theme)
            }
        }
        .defaultSize(width: 1180, height: 740)
        .commands {
            CommandMenu("Workspace") {
                Button("Previous Terminal Tab") {
                    store.selectPreviousTerminalSpaceTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(!store.canCycleOpenTerminalSpaceTabs)

                Button("Next Terminal Tab") {
                    store.selectNextTerminalSpaceTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(!store.canCycleOpenTerminalSpaceTabs)

                Button("Close Terminal Tab") {
                    guard let selectedSpaceID = store.document.selectedSpaceID else {
                        return
                    }
                    store.closeTerminalSpaceTab(withID: selectedSpaceID)
                }
                .keyboardShortcut("w", modifiers: [.command])
                .disabled(store.document.selectedSpaceID == nil)

                Divider()

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

                Button("New Note") {
                    store.addNote()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(store.selectedProject == nil)

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
                .disabled(!canToggleFocusedPaneEditor)

                Divider()

                Button("New Note Pane on Right") {
                    store.addNotePane(axis: .horizontal)
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!store.canAddPane)

                Button("New Note Pane Below") {
                    store.addNotePane(axis: .vertical)
                }
                .keyboardShortcut("n", modifiers: [.command, .option, .shift])
                .disabled(!store.canAddPane)

                if let project = store.selectedProject,
                    !project.notes.isEmpty
                {
                    Menu("Open Existing Note in Pane") {
                        ForEach(project.notes) { note in
                            Menu(note.name) {
                                Button("Open on Right") {
                                    store.openNoteInNewPane(
                                        noteID: note.id,
                                        inProjectWithID: project.id,
                                        axis: .horizontal
                                    )
                                }
                                Button("Open Below") {
                                    store.openNoteInNewPane(
                                        noteID: note.id,
                                        inProjectWithID: project.id,
                                        axis: .vertical
                                    )
                                }
                            }
                        }
                    }
                    .disabled(!store.canAddPane)
                }

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
                    saveFocusedDocument()
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(!canSaveFocusedDocument)
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

    private var canSaveFocusedDocument: Bool {
        switch focusedDocumentSaveTarget {
        case .editor(let paneID):
            return editors.session(forPaneID: paneID)?.selectedBuffer?.canSave == true
        case .note(let noteID):
            guard let note = store.document.note(withID: noteID) else {
                return false
            }
            return notes.session(for: note).canSave
        case .none:
            return false
        }
    }

    private var canToggleFocusedPaneEditor: Bool {
        isFocusedPaneEditorPresented || store.canPresentEditorInFocusedPane
    }

    private func toggleFocusedPaneEditor() {
        guard let focusedPaneID = store.focusedPaneID else {
            return
        }
        if editors.isEditorPresented(inPaneID: focusedPaneID) {
            editors.dismissEditor(inPaneID: focusedPaneID)
            sessions.focus(paneID: focusedPaneID)
        } else {
            guard store.canPresentEditorInFocusedPane else {
                return
            }
            sessions.dismissPDFPreview(inPaneID: focusedPaneID)
            editors.presentEditor(inPaneID: focusedPaneID)
        }
    }

    private func saveFocusedDocument() {
        switch focusedDocumentSaveTarget {
        case .editor(let paneID):
            guard let session = editors.session(forPaneID: paneID) else {
                return
            }
            Task {
                await session.saveSelectedBuffer()
            }
        case .note(let noteID):
            notes.save(noteID: noteID)
        case .none:
            break
        }
    }

    private var focusedDocumentSaveTarget: FocusedDocumentSaveTarget {
        FocusedDocumentSaveTarget.resolve(
            focusedPaneID: store.focusedPaneID,
            focusedPaneNoteID: store.focusedPaneNote?.id,
            selectedNoteID: store.selectedNote?.id,
            isFocusedPaneEditorPresented: isFocusedPaneEditorPresented
        )
    }

    private func setSidebarVisible(_ isVisible: Bool) {
        SidebarMotion.setSidebarVisible(
            isVisible,
            store: store,
            sessions: sessions
        )
    }
}

enum FocusedDocumentSaveTarget: Equatable {
    case editor(UUID)
    case note(UUID)
    case none

    static func resolve(
        focusedPaneID: UUID?,
        focusedPaneNoteID: UUID?,
        selectedNoteID: UUID?,
        isFocusedPaneEditorPresented: Bool
    ) -> FocusedDocumentSaveTarget {
        if isFocusedPaneEditorPresented,
            let focusedPaneID
        {
            return .editor(focusedPaneID)
        }
        if let focusedPaneNoteID {
            return .note(focusedPaneNoteID)
        }
        if let selectedNoteID {
            return .note(selectedNoteID)
        }
        return .none
    }
}
