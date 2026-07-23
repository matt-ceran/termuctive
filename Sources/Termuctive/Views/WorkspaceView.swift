import AppKit
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var sessions: TerminalSessionPool
    @ObservedObject var editors: EditorSessionPool
    @ObservedObject var appearance: AppearanceSettings

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                ProjectSidebar(
                    store: store,
                    editors: editors,
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
        }
        .onChange(of: store.document.terminalIDs) { _, paneIDs in
            sessions.reconcile(validPaneIDs: paneIDs)
            editors.reconcile(validPaneIDs: paneIDs)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        ) {
            _ in
            sessions.terminateAll()
            editors.terminateAll()
        }
        .alert(
            "Termuctive",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { presented in
                    if !presented {
                        store.dismissError()
                    }
                }
            )
        ) {
            Button("OK") {
                store.dismissError()
            }
        } message: {
            Text(store.errorMessage ?? "")
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

    private var workspaceBar: some View {
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

            if let project = store.selectedProject {
                Text(project.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let space = store.selectedSpace {
                    Text("/")
                        .foregroundStyle(.tertiary)
                    Text(space.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Menu {
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
            } label: {
                Image(systemName: "circle.lefthalf.filled")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30, height: 30)
            .help("Appearance")
            .accessibilityLabel("Appearance options")

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
            .disabled(store.focusedPaneID == nil)
            .help(isFocusedPaneEditorPresented ? "Return to Terminal" : "Open IDE")
            .accessibilityLabel(
                isFocusedPaneEditorPresented
                    ? "Return focused pane to terminal"
                    : "Open IDE in focused pane"
            )

            Button {
                store.splitFocusedPane(axis: .horizontal)
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .buttonStyle(SquareIconButtonStyle())
            .disabled(store.focusedPaneID == nil)
            .help("Split Right")
            .accessibilityLabel("Split terminal right")

            Button {
                store.splitFocusedPane(axis: .vertical)
            } label: {
                Image(systemName: "rectangle.split.1x2")
            }
            .buttonStyle(SquareIconButtonStyle())
            .disabled(store.focusedPaneID == nil)
            .help("Split Down")
            .accessibilityLabel("Split terminal down")

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

            Button {
                guard let focusedPaneID = store.focusedPaneID else {
                    return
                }
                editors.requestClosePane(withID: focusedPaneID)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(SquareIconButtonStyle())
            .disabled(!store.canCloseFocusedPane)
            .help("Close Pane")
            .accessibilityLabel("Close terminal pane")
        }
        .padding(.horizontal, 6)
        .frame(height: 40)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var workspaceContent: some View {
        if let space = store.selectedSpace {
            if let zoomedPaneID = store.zoomedPaneID,
                let pane = space.layout.terminal(withID: zoomedPaneID)
            {
                PaneTreeView(
                    node: .terminal(pane),
                    store: store,
                    sessions: sessions,
                    editors: editors
                )
            } else {
                PaneTreeView(
                    node: space.layout,
                    store: store,
                    sessions: sessions,
                    editors: editors
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

    private var pendingPaneCloseTitle: String {
        guard let pendingClosePaneID = editors.pendingClosePaneID,
            let pane = store.selectedSpace?.layout.terminal(withID: pendingClosePaneID)
        else {
            return "Close Pane?"
        }
        return "Close \(sessions.title(for: pane))?"
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
