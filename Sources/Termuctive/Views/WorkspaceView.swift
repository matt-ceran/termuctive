import AppKit
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var sessions: TerminalSessionPool

    var body: some View {
        HStack(spacing: 0) {
            if store.isSidebarVisible {
                ProjectSidebar(store: store, chooseProject: chooseProject)
                    .frame(width: 240)
                Divider()
            }

            VStack(spacing: 0) {
                workspaceBar
                Divider()
                workspaceContent
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            sessions.reconcile(validPaneIDs: store.document.terminalIDs)
        }
        .onChange(of: store.document.terminalIDs) { _, paneIDs in
            sessions.reconcile(validPaneIDs: paneIDs)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        ) {
            _ in
            sessions.terminateAll()
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
    }

    private var workspaceBar: some View {
        HStack(spacing: 6) {
            if !store.isSidebarVisible {
                Button {
                    store.isSidebarVisible = true
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
                store.closeFocusedPane()
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
                PaneTreeView(node: .terminal(pane), store: store, sessions: sessions)
            } else {
                PaneTreeView(node: space.layout, store: store, sessions: sessions)
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
}
