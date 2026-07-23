import AppKit
import SwiftUI

struct EditorPaneContainerView: View {
    let pane: TerminalPane
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var terminalSessions: TerminalSessionPool
    @ObservedObject var editorSessions: EditorSessionPool
    @ObservedObject var session: EditorPaneSession

    var body: some View {
        VStack(spacing: 0) {
            if let buffer = session.selectedBuffer {
                EditorPaneHeaderView(
                    pane: pane,
                    store: store,
                    terminalSessions: terminalSessions,
                    editorSessions: editorSessions,
                    session: session,
                    buffer: buffer
                )
            } else {
                EditorPaneEmptyHeaderView(
                    pane: pane,
                    store: store,
                    terminalSessions: terminalSessions,
                    editorSessions: editorSessions,
                    session: session
                )
            }

            EditorWorkspaceView(
                store: store,
                session: session
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.rootURL.lastPathComponent) code editor")
    }
}

private struct EditorPaneHeaderView: View {
    let pane: TerminalPane
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var terminalSessions: TerminalSessionPool
    @ObservedObject var editorSessions: EditorSessionPool
    @ObservedObject var session: EditorPaneSession
    @ObservedObject var buffer: EditorDocumentBuffer

    var body: some View {
        HStack(spacing: 8) {
            navigatorButton

            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 11, weight: .medium))

            HStack(spacing: 4) {
                Text(buffer.url.lastPathComponent)
                    .lineLimit(1)
                if buffer.isDirty {
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("Unsaved changes")
                }
            }

            Spacer(minLength: 8)

            if let statusMessage = buffer.statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(abbreviatedPath(buffer.url.deletingLastPathComponent().path))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if buffer.isSaving {
                ProgressView()
                    .controlSize(.small)
                    .help("Saving")
            }

            Button {
                Task {
                    await session.saveSelectedBuffer()
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.plain)
            .disabled(!buffer.canSave)
            .keyboardShortcut("s", modifiers: [.command])
            .help("Save File")
            .accessibilityLabel("Save file")

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([buffer.url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .help("Reveal File in Finder")
            .accessibilityLabel("Reveal file in Finder")

            returnToTerminalButton
            closePaneButton
        }
        .font(.system(size: 11))
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture {
            store.focusPane(withID: pane.id)
        }
    }

    private var navigatorButton: some View {
        Button {
            session.isNavigatorVisible.toggle()
        } label: {
            Image(systemName: "sidebar.left")
        }
        .buttonStyle(.plain)
        .help(session.isNavigatorVisible ? "Hide File Navigator" : "Show File Navigator")
        .accessibilityLabel(
            session.isNavigatorVisible ? "Hide file navigator" : "Show file navigator"
        )
    }

    private var returnToTerminalButton: some View {
        Button {
            editorSessions.dismissEditor(inPaneID: pane.id)
            terminalSessions.focus(paneID: pane.id)
        } label: {
            Image(systemName: "terminal")
        }
        .buttonStyle(.plain)
        .help("Return to Terminal")
        .accessibilityLabel("Return to terminal")
    }

    private var closePaneButton: some View {
        Button {
            editorSessions.requestClosePane(withID: pane.id)
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .help("Close Pane")
        .accessibilityLabel("Close pane")
    }
}

private struct EditorPaneEmptyHeaderView: View {
    let pane: TerminalPane
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var terminalSessions: TerminalSessionPool
    @ObservedObject var editorSessions: EditorSessionPool
    @ObservedObject var session: EditorPaneSession

    var body: some View {
        HStack(spacing: 8) {
            Button {
                session.isNavigatorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.plain)
            .help(session.isNavigatorVisible ? "Hide File Navigator" : "Show File Navigator")
            .accessibilityLabel(
                session.isNavigatorVisible ? "Hide file navigator" : "Show file navigator"
            )

            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 11, weight: .medium))
            Text(session.rootURL.lastPathComponent)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(abbreviatedPath(session.rootURL.path))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                editorSessions.dismissEditor(inPaneID: pane.id)
                terminalSessions.focus(paneID: pane.id)
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.plain)
            .help("Return to Terminal")
            .accessibilityLabel("Return to terminal")

            Button {
                editorSessions.requestClosePane(withID: pane.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close Pane")
            .accessibilityLabel("Close pane")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture {
            store.focusPane(withID: pane.id)
        }
    }
}

private struct EditorWorkspaceView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var session: EditorPaneSession

    var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width < 560
            ZStack(alignment: .leading) {
                if isCompact {
                    editorSurface
                    if session.isNavigatorVisible {
                        navigator(isCompact: true)
                            .frame(
                                width: min(
                                    max(geometry.size.width * 0.78, 190),
                                    280
                                )
                            )
                            .background(.regularMaterial)
                            .shadow(color: .black.opacity(0.24), radius: 10, x: 3)
                            .transition(.move(edge: .leading))
                    }
                } else {
                    HStack(spacing: 0) {
                        if session.isNavigatorVisible {
                            navigator(isCompact: false)
                                .frame(
                                    width: min(
                                        max(geometry.size.width * 0.28, 170),
                                        220
                                    )
                                )
                            Divider()
                        }
                        editorSurface
                    }
                }
            }
            .animation(.smooth(duration: 0.18), value: session.isNavigatorVisible)
        }
        .confirmationDialog(
            pendingBufferCloseTitle,
            isPresented: Binding(
                get: { session.pendingCloseBufferID != nil },
                set: { isPresented in
                    if !isPresented {
                        session.cancelPendingBufferClose()
                    }
                }
            )
        ) {
            Button("Save and Close") {
                Task {
                    await session.saveAndClosePendingBuffer()
                }
            }
            Button("Close Without Saving", role: .destructive) {
                session.discardAndClosePendingBuffer()
            }
            Button("Cancel", role: .cancel) {
                session.cancelPendingBufferClose()
            }
        } message: {
            Text("This file has unsaved changes.")
        }
    }

    private var editorSurface: some View {
        VStack(spacing: 0) {
            if let errorMessage = session.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(errorMessage)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        session.dismissError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss editor error")
                }
                .font(.system(size: 11))
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background(Color(nsColor: .systemYellow).opacity(0.18))
            }

            if session.buffers.isEmpty {
                ContentUnavailableView {
                    Label(
                        "Select a file to edit",
                        systemImage: "chevron.left.forwardslash.chevron.right"
                    )
                }
            } else {
                EditorTabBar(session: session)
                Divider()
                if let buffer = session.selectedBuffer {
                    EditorBufferView(
                        store: store,
                        session: session,
                        buffer: buffer
                    )
                    .id(buffer.id)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func navigator(isCompact: Bool) -> some View {
        EditorNavigatorView(
            session: session,
            collapseAfterOpeningFile: isCompact
        )
    }

    private var pendingBufferCloseTitle: String {
        guard let pendingCloseBufferID = session.pendingCloseBufferID,
            let buffer = session.buffers.first(where: { $0.id == pendingCloseBufferID })
        else {
            return "Close File?"
        }
        return "Save changes to \(buffer.url.lastPathComponent)?"
    }
}

private struct EditorNavigatorView: View {
    @ObservedObject var session: EditorPaneSession
    let collapseAfterOpeningFile: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(session.rootURL.lastPathComponent)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if session.isRefreshingFileTree {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    session.refreshFileTree()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh Files")
                .accessibilityLabel("Refresh files")
            }
            .padding(.horizontal, 8)
            .frame(height: 28)

            TextField("Filter Files", text: $session.searchText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .padding(.horizontal, 7)
                .padding(.bottom, 6)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(filteredNodes) { node in
                        EditorNavigatorNodeView(
                            node: node,
                            session: session,
                            collapseAfterOpeningFile: collapseAfterOpeningFile,
                            searchIsActive: !trimmedSearchText.isEmpty,
                            depth: 0
                        )
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if session.fileTree.isTruncated {
                Divider()
                Text("Showing the first 50,000 files")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityLabel("Project files")
    }

    private var trimmedSearchText: String {
        session.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredNodes: [EditorFileNode] {
        guard !trimmedSearchText.isEmpty else {
            return session.fileTree.nodes
        }
        return filter(
            session.fileTree.nodes,
            query: trimmedSearchText.localizedLowercase
        )
    }

    private func filter(_ nodes: [EditorFileNode], query: String) -> [EditorFileNode] {
        nodes.compactMap { node in
            let filteredChildren = filter(node.children, query: query)
            if node.name.localizedLowercase.contains(query) || !filteredChildren.isEmpty {
                return EditorFileNode(
                    url: node.url,
                    isDirectory: node.isDirectory,
                    children: filteredChildren
                )
            }
            return nil
        }
    }
}

private struct EditorNavigatorNodeView: View {
    let node: EditorFileNode
    @ObservedObject var session: EditorPaneSession
    let collapseAfterOpeningFile: Bool
    let searchIsActive: Bool
    let depth: Int

    @State private var isExpanded = false

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: expansionBinding) {
                ForEach(node.children) { child in
                    EditorNavigatorNodeView(
                        node: child,
                        session: session,
                        collapseAfterOpeningFile: collapseAfterOpeningFile,
                        searchIsActive: searchIsActive,
                        depth: depth + 1
                    )
                }
            } label: {
                Label(node.name, systemImage: "folder")
                    .lineLimit(1)
            }
            .font(.system(size: 11))
            .padding(.leading, CGFloat(depth * 10 + 6))
        } else {
            Button {
                Task {
                    await session.openFile(
                        node.url,
                        collapseNavigator: collapseAfterOpeningFile
                    )
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: fileIconName)
                        .frame(width: 13)
                    Text(node.name)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .padding(.leading, CGFloat(depth * 10 + 18))
            .padding(.trailing, 6)
            .frame(height: 21)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.16)
                    : Color.clear
            )
            .accessibilityLabel("Open \(node.name)")
        }
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { searchIsActive || isExpanded },
            set: { expanded in
                if !searchIsActive {
                    isExpanded = expanded
                }
            }
        )
    }

    private var fileIconName: String {
        let codeExtensions: Set<String> = [
            "c", "cc", "cpp", "cs", "css", "go", "h", "hpp", "html", "java", "js", "jsx",
            "kt", "kts", "m", "mm", "php", "py", "rb", "rs", "sh", "swift", "ts", "tsx",
        ]
        return codeExtensions.contains(node.url.pathExtension.lowercased())
            ? "chevron.left.forwardslash.chevron.right"
            : "doc"
    }

    private var isSelected: Bool {
        session.selectedBuffer?.url == node.url
    }
}

private struct EditorTabBar: View {
    @ObservedObject var session: EditorPaneSession

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(session.buffers) { buffer in
                    EditorTabView(
                        buffer: buffer,
                        isSelected: session.selectedBufferID == buffer.id,
                        select: {
                            session.selectBuffer(withID: buffer.id)
                        },
                        close: {
                            session.requestCloseBuffer(withID: buffer.id)
                        }
                    )
                }
            }
        }
        .frame(height: 29)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityLabel("Open files")
    }
}

private struct EditorTabView: View {
    @ObservedObject var buffer: EditorDocumentBuffer
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Button(action: select) {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text")
                    Text(buffer.url.lastPathComponent)
                        .lineLimit(1)
                    if buffer.isDirty {
                        Circle()
                            .fill(Color.primary)
                            .frame(width: 5, height: 5)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(buffer.url.lastPathComponent)")
        }
        .font(.system(size: 10))
        .padding(.horizontal, 8)
        .frame(height: 29)
        .background(
            isSelected
                ? Color(nsColor: .textBackgroundColor)
                : Color.clear
        )
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 1)
            }
        }
        .overlay(alignment: .trailing) {
            Divider()
        }
    }
}

private struct EditorBufferView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var session: EditorPaneSession
    @ObservedObject var buffer: EditorDocumentBuffer

    var body: some View {
        VStack(spacing: 0) {
            if let externalChange = buffer.externalChange {
                externalChangeBanner(externalChange)
            }

            CodeEditorView(
                buffer: buffer,
                focusHandler: {
                    store.focusPane(withID: session.id)
                },
                saveHandler: {
                    Task {
                        await session.saveSelectedBuffer()
                    }
                }
            )

            Divider()

            HStack(spacing: 12) {
                Text("Ln \(buffer.cursorLine), Col \(buffer.cursorColumn)")
                Spacer()
                Text(buffer.lineEndingTitle)
                Text(buffer.encodingTitle)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func externalChangeBanner(_ change: EditorExternalChange) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text(externalChangeMessage(change))
                .lineLimit(2)
            Spacer()
            if case .modified = change {
                Button("Reload Disk") {
                    buffer.reloadExternalVersion()
                }
                .buttonStyle(.borderless)
            }
            Button("Keep Mine") {
                buffer.keepLocalVersion()
            }
            .buttonStyle(.borderless)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 9)
        .frame(minHeight: 32)
        .background(Color(nsColor: .systemOrange).opacity(0.16))
    }

    private func externalChangeMessage(_ change: EditorExternalChange) -> String {
        switch change {
        case .modified:
            "This file changed on disk while you have unsaved edits."
        case .deleted:
            "This file was deleted on disk."
        }
    }
}

private func abbreviatedPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    guard path.hasPrefix(home) else {
        return path
    }
    return "~" + path.dropFirst(home.count)
}
