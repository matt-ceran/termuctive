import AppKit
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var sessions: TerminalSessionPool
    @ObservedObject var editors: EditorSessionPool
    @ObservedObject var notes: NoteSessionPool
    @ObservedObject var appearance: AppearanceSettings
    let agentActivity: AgentActivityRegistry
    @State private var activityTopology = WorkspaceActivityTopology()

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                ProjectSidebar(
                    store: store,
                    editors: editors,
                    notes: notes,
                    agentActivity: agentActivity,
                    activityIndicatorsVisible: store.isSidebarVisible,
                    chooseProject: chooseProject,
                    hideSidebar: { setSidebarVisible(false) }
                )
                .frame(width: 240)
                Divider()
            }
            .frame(
                width: store.isSidebarVisible ? 241 : 0,
                alignment: .leading
            )
            .clipped()
            .allowsHitTesting(store.isSidebarVisible)
            .accessibilityHidden(!store.isSidebarVisible)

            VStack(spacing: 0) {
                workspaceBar
                Divider()
                workspaceContent
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            sessions.reconcile(validPaneIDs: store.document.terminalIDs)
            editors.reconcile(validPaneIDs: store.document.terminalIDs)
            notes.reconcile(validNoteIDs: store.document.noteIDs)
            refreshVisibleEditorPanes()
            refreshActivityTopology()
        }
        .onChange(of: store.document.terminalIDs) { _, paneIDs in
            sessions.reconcile(validPaneIDs: paneIDs)
            editors.reconcile(validPaneIDs: paneIDs)
            refreshVisibleEditorPanes()
            refreshActivityTopology()
        }
        .onChange(of: store.document.noteIDs) { _, noteIDs in
            notes.reconcile(validNoteIDs: noteIDs)
        }
        .onChange(of: renderedEditorPaneIDs) { _, paneIDs in
            editors.setVisiblePaneIDs(paneIDs)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        ) {
            _ in
            sessions.terminateAll()
            editors.terminateAll()
            notes.terminateAll()
        }
        .alert(
            "Termuctive",
            isPresented: Binding(
                get: { store.errorMessage != nil || notes.errorMessage != nil },
                set: { presented in
                    if !presented {
                        store.dismissError()
                        notes.dismissError()
                    }
                }
            )
        ) {
            Button("OK") {
                store.dismissError()
                notes.dismissError()
            }
        } message: {
            Text(store.errorMessage ?? notes.errorMessage ?? "")
        }
        .confirmationDialog(
            pendingPaneCloseTitle,
            isPresented: Binding(
                get: { editors.pendingClosePaneID != nil },
                set: { isPresented in
                    if !isPresented {
                        editors.cancelPendingPaneClose()
                    }
                }
            )
        ) {
            Button("Save All and Close Pane") {
                Task {
                    await editors.saveAndClosePendingPane()
                }
            }
            Button("Close Pane Without Saving", role: .destructive) {
                editors.discardAndClosePendingPane()
            }
            Button("Cancel", role: .cancel) {
                editors.cancelPendingPaneClose()
            }
        } message: {
            Text("One or more files in this editor have unsaved changes.")
        }
    }

    private func refreshActivityTopology() {
        let topology = WorkspaceActivityTopology(document: store.document)
        guard activityTopology != topology else {
            return
        }
        activityTopology = topology
        agentActivity.reconcile(topology: topology)
    }

    private func refreshVisibleEditorPanes() {
        editors.setVisiblePaneIDs(renderedEditorPaneIDs)
    }

    var renderedEditorPaneIDs: Set<UUID> {
        guard let selectedSpace = store.selectedSpace else {
            return []
        }
        let renderedPaneIDs: Set<UUID>
        if let zoomedPaneID = store.zoomedPaneID,
            selectedSpace.layout.terminalIDs.contains(zoomedPaneID)
        {
            renderedPaneIDs = [zoomedPaneID]
        } else {
            renderedPaneIDs = selectedSpace.layout.terminalIDs
        }
        return renderedPaneIDs.filter { paneID in
            editors.isEditorPresented(inPaneID: paneID)
                && sessions.previewURL(for: paneID) == nil
        }
    }

    private var workspaceBar: some View {
        GeometryReader { geometry in
            HStack(spacing: 6) {
                if !store.isSidebarVisible {
                    Button {
                        setSidebarVisible(true)
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .buttonStyle(SquareIconButtonStyle())
                    .accessibilityLabel("Show projects")
                }

                TerminalSpaceTabStrip(
                    store: store,
                    agentActivity: agentActivity,
                    selectTab: selectTerminalSpaceTab
                )
                .frame(minWidth: 112, maxWidth: .infinity)
                .clipped()

                terminalSpaceMenu
                    .fixedSize()

                workspaceActions(for: geometry.size.width)
                    .fixedSize()
                    .layoutPriority(1)
            }
            .padding(.horizontal, 6)
            .frame(width: geometry.size.width, height: 40)
        }
        .frame(height: 40)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func workspaceActions(for availableWidth: CGFloat) -> some View {
        if availableWidth >= 520 {
            fullWorkspaceActions
        } else if availableWidth >= 390 {
            compactWorkspaceActions
        } else {
            workspaceActionsMenu
        }
    }

    private var terminalSpaceMenu: some View {
        Menu {
            ForEach(store.document.projects) { project in
                if !project.terminalSpaces.isEmpty {
                    Menu(project.name) {
                        ForEach(project.terminalSpaces) { space in
                            let spacePath =
                                project.namePath(forItemWithID: space.id)?
                                .joined(separator: " / ") ?? space.name
                            Button {
                                store.selectSpace(withID: space.id, inProject: project.id)
                            } label: {
                                if store.document.selectedSpaceID == space.id {
                                    Label(spacePath, systemImage: "checkmark")
                                } else {
                                    Text(spacePath)
                                }
                            }
                        }
                    }
                }
            }
            if !store.document.projects.isEmpty {
                Divider()
            }
            Button("New Terminal Space") {
                store.addSpace()
            }
            .disabled(store.selectedProject == nil)
            Button("Add Project...", action: chooseProject)
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 30, height: 30)
        .help("Open terminal tab")
        .accessibilityLabel("Open terminal tab")
    }

    private var fullWorkspaceActions: some View {
        HStack(spacing: 6) {
            appearanceMenu
            editorButton
            notePaneMenu
            splitRightButton
            splitDownButton
            zoomButton
            closePaneButton
        }
    }

    private var compactWorkspaceActions: some View {
        HStack(spacing: 6) {
            editorButton
            notePaneMenu
            workspaceActionsMenu
        }
    }

    private var appearanceMenu: some View {
        Menu {
            appearancePickers
        } label: {
            Image(systemName: "circle.lefthalf.filled")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 30, height: 30)
        .help("Appearance")
        .accessibilityLabel("Appearance options")
    }

    @ViewBuilder
    private var appearancePickers: some View {
        Picker("App Appearance", selection: $appearance.appTheme) {
            ForEach(AppTheme.allCases) { theme in
                Text(theme.title).tag(theme)
            }
        }
        Picker("Terminal Appearance", selection: $appearance.terminalTheme) {
            ForEach(TerminalTheme.allCases) { theme in
                Text(theme.title).tag(theme)
            }
        }
    }

    private var editorButton: some View {
        Button {
            toggleFocusedPaneEditor()
        } label: {
            Image(
                systemName: isFocusedPaneEditorPresented
                    ? "terminal"
                    : "chevron.left.forwardslash.chevron.right"
            )
        }
        .buttonStyle(SquareIconButtonStyle())
        .disabled(!canToggleFocusedPaneEditor)
        .help(isFocusedPaneEditorPresented ? "Return to Terminal" : "Open IDE")
        .accessibilityLabel(
            isFocusedPaneEditorPresented
                ? "Return focused pane to terminal"
                : "Open IDE in focused pane"
        )
    }

    private var notePaneMenu: some View {
        Menu {
            notePaneActions
        } label: {
            Image(systemName: "note.text.badge.plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 30, height: 30)
        .disabled(!store.canAddPane)
        .help("Add Note Pane")
        .accessibilityLabel("Add note pane")
    }

    @ViewBuilder
    private var notePaneActions: some View {
        Button("New Note Pane on Right") {
            store.addNotePane(axis: .horizontal)
        }
        Button("New Note Pane Below") {
            store.addNotePane(axis: .vertical)
        }
        if let project = store.selectedProject,
            !project.notes.isEmpty
        {
            Divider()
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
    }

    private var splitRightButton: some View {
        Button {
            store.splitFocusedPane(axis: .horizontal)
        } label: {
            Image(systemName: "rectangle.split.2x1")
        }
        .buttonStyle(SquareIconButtonStyle())
        .disabled(store.focusedPaneID == nil)
        .help("Split Right")
        .accessibilityLabel("Split terminal right")
    }

    private var splitDownButton: some View {
        Button {
            store.splitFocusedPane(axis: .vertical)
        } label: {
            Image(systemName: "rectangle.split.1x2")
        }
        .buttonStyle(SquareIconButtonStyle())
        .disabled(store.focusedPaneID == nil)
        .help("Split Down")
        .accessibilityLabel("Split terminal down")
    }

    private var zoomButton: some View {
        Button {
            togglePaneZoom()
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(SquareIconButtonStyle())
        .disabled(!store.canZoomFocusedPane)
        .help(store.isFocusedPaneZoomed ? "Show All Panes" : "Zoom Focused Pane")
        .accessibilityLabel(
            store.isFocusedPaneZoomed ? "Show all terminal panes" : "Zoom focused terminal pane"
        )
    }

    private var closePaneButton: some View {
        Button(action: requestFocusedPaneClose) {
            Image(systemName: "xmark")
        }
        .buttonStyle(SquareIconButtonStyle())
        .disabled(!store.canCloseFocusedPane)
        .help("Close Pane")
        .accessibilityLabel("Close terminal pane")
    }

    private var workspaceActionsMenu: some View {
        Menu {
            appearancePickers
            Divider()
            Button(isFocusedPaneEditorPresented ? "Return to Terminal" : "Open IDE") {
                toggleFocusedPaneEditor()
            }
            .disabled(!canToggleFocusedPaneEditor)
            Menu("Note Panes") {
                notePaneActions
            }
            .disabled(!store.canAddPane)
            Button("Split Right") {
                store.splitFocusedPane(axis: .horizontal)
            }
            .disabled(store.focusedPaneID == nil)
            Button("Split Down") {
                store.splitFocusedPane(axis: .vertical)
            }
            .disabled(store.focusedPaneID == nil)
            Button(store.isFocusedPaneZoomed ? "Show All Panes" : "Zoom Focused Pane") {
                togglePaneZoom()
            }
            .disabled(!store.canZoomFocusedPane)
            Divider()
            Button("Close Pane", action: requestFocusedPaneClose)
                .disabled(!store.canCloseFocusedPane)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 30, height: 30)
        .help("Pane actions")
        .accessibilityLabel("Pane actions")
    }

    @ViewBuilder
    private var workspaceContent: some View {
        if let note = store.selectedNote {
            ProjectNoteView(
                note: note,
                session: notes.session(for: note)
            )
            .id(note.id)
        } else if let space = store.selectedSpace {
            if let zoomedPaneID = store.zoomedPaneID,
                let pane = space.layout.terminal(withID: zoomedPaneID)
            {
                PaneTreeView(
                    node: .terminal(pane),
                    store: store,
                    sessions: sessions,
                    editors: editors,
                    notes: notes
                )
            } else {
                PaneTreeView(
                    node: space.layout,
                    store: store,
                    sessions: sessions,
                    editors: editors,
                    notes: notes
                )
            }
        } else {
            ZStack {
                Color(nsColor: .textBackgroundColor)
                Button(
                    store.selectedProject == nil ? "Add Project" : "New Terminal Space",
                    action: store.selectedProject == nil ? chooseProject : store.addSpace
                )
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose a project directory."
        panel.prompt = "Add Project"
        panel.begin { response in
            guard response == .OK,
                let url = panel.url
            else {
                return
            }
            Task { @MainActor in
                store.addProject(at: url)
            }
        }
    }

    private func togglePaneZoom() {
        store.toggleFocusedPaneZoom()
        if let focusedPaneID = store.focusedPaneID {
            sessions.focus(paneID: focusedPaneID)
        }
    }

    private var isFocusedPaneEditorPresented: Bool {
        guard let focusedPaneID = store.focusedPaneID else {
            return false
        }
        return editors.isEditorPresented(inPaneID: focusedPaneID)
    }

    private var canToggleFocusedPaneEditor: Bool {
        isFocusedPaneEditorPresented || store.canPresentEditorInFocusedPane
    }

    private var pendingPaneCloseTitle: String {
        guard let pendingClosePaneID = editors.pendingClosePaneID,
            let pane = store.document.terminal(withID: pendingClosePaneID)
        else {
            return "Close Pane?"
        }
        return "Close \(sessions.title(for: pane))?"
    }

    private func requestFocusedPaneClose() {
        guard let focusedPaneID = store.focusedPaneID else {
            return
        }
        editors.requestClosePane(withID: focusedPaneID)
    }

    private func selectTerminalSpaceTab(_ spaceID: UUID) {
        store.selectTerminalSpaceTab(withID: spaceID)
        Task { @MainActor in
            await Task.yield()
            guard store.document.selectedSpaceID == spaceID,
                let pane = store.focusedPane,
                pane.content == .terminal,
                !editors.isEditorPresented(inPaneID: pane.id),
                sessions.previewURL(for: pane.id) == nil
            else {
                return
            }
            sessions.focus(paneID: pane.id)
        }
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

    private func setSidebarVisible(_ isVisible: Bool) {
        SidebarMotion.setSidebarVisible(
            isVisible,
            store: store,
            sessions: sessions
        )
    }
}
