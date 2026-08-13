import SwiftUI

struct ProjectSidebar: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var editors: EditorSessionPool
    @ObservedObject var notes: NoteSessionPool
    let agentActivity: AgentActivityRegistry
    let activityIndicatorsVisible: Bool
    let chooseProject: () -> Void
    let hideSidebar: () -> Void

    @State private var renamingEntry: SidebarEntry?
    @State private var renameDraft = ""
    @State private var pendingRemoval: SidebarEntry?
    @FocusState private var focusedRenameID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Projects")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .layoutPriority(1)
                Spacer()
                Menu {
                    Button("Add Project...", action: chooseProject)
                    Divider()
                    Button("New Folder") {
                        store.addFolder()
                    }
                    .disabled(store.selectedProject == nil)
                    Button("New Terminal Space") {
                        store.addSpace()
                    }
                    .disabled(store.selectedProject == nil)
                    Button("New Note") {
                        store.addNote()
                    }
                    .disabled(store.selectedProject == nil)
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 30, height: 30)
                .accessibilityLabel("Add workspace item")

                Button {
                    hideSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(SquareIconButtonStyle())
                .accessibilityLabel("Hide projects")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 40)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.document.projects) { project in
                        projectSection(project)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: focusedRenameID) { previous, current in
            if previous != nil,
                current == nil,
                renamingEntry != nil
            {
                commitRename()
            }
        }
        .alert(
            pendingRemoval?.removalTitle ?? "Remove item?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { presented in
                    if !presented {
                        pendingRemoval = nil
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
            if pendingRemovalHasUnsavedChanges {
                Button("Save All and \(pendingRemoval?.removeLabel ?? "Remove")") {
                    saveAndRemovePendingEntry()
                }
                Button(
                    "\(pendingRemoval?.removeLabel ?? "Remove") Without Saving",
                    role: .destructive
                ) {
                    removePendingEntry()
                }
            } else {
                Button(pendingRemoval?.removeLabel ?? "Remove", role: .destructive) {
                    removePendingEntry()
                }
            }
        } message: {
            Text(pendingRemovalMessage)
        }
    }

    @ViewBuilder
    private func projectSection(_ project: TerminalProject) -> some View {
        let isExpanded = store.expandedProjectIDs.contains(project.id)
        VStack(spacing: 0) {
            sidebarRow(
                entry: .project(id: project.id, name: project.name, kind: project.kind),
                disclosureIcon: "chevron.right",
                rotatesDisclosureIcon: isExpanded,
                secondaryIcon: "folder",
                title: project.name,
                depth: 0,
                selected: store.document.selectedProjectID == project.id
                    && store.document.selectedItemID == nil
                    && store.selectedFolderID == nil,
                activity: SidebarRowActivity(
                    scope: .project(project.id),
                    isPresented: !isExpanded,
                    isVisible: activityIndicatorsVisible
                )
            ) {
                if store.document.selectedProjectID == project.id {
                    withAnimation(SidebarMotion.disclosure) {
                        store.toggleProject(withID: project.id)
                    }
                } else {
                    store.selectProject(withID: project.id)
                }
            }

            SidebarDisclosureSection(
                isExpanded: isExpanded,
                contentHeight: disclosureHeight(for: project.items)
            ) {
                LazyVStack(spacing: 0) {
                    ForEach(project.items) { item in
                        itemRow(
                            item,
                            projectID: project.id,
                            depth: 1,
                            isVisible: activityIndicatorsVisible && isExpanded
                        )
                    }
                }
            }
        }
    }

    private func itemRow(
        _ item: WorkspaceItem,
        projectID: UUID,
        depth: Int,
        isVisible: Bool
    ) -> AnyView {
        switch item {
        case .note(let note):
            return AnyView(
                sidebarRow(
                    entry: .note(id: note.id, projectID: projectID, name: note.name),
                    disclosureIcon: nil,
                    secondaryIcon: "note.text",
                    title: note.name,
                    depth: depth,
                    selected: store.document.selectedItemID == note.id
                        && store.selectedFolderID == nil
                ) {
                    store.selectNote(withID: note.id, inProject: projectID)
                }
            )

        case .space(let space):
            return AnyView(
                sidebarRow(
                    entry: .space(id: space.id, projectID: projectID, name: space.name),
                    disclosureIcon: nil,
                    secondaryIcon: "rectangle",
                    title: space.name,
                    depth: depth,
                    selected: store.document.selectedItemID == space.id
                        && store.selectedFolderID == nil,
                    activity: SidebarRowActivity(
                        scope: .space(space.id),
                        isPresented: true,
                        isVisible: isVisible
                    )
                ) {
                    store.selectSpace(withID: space.id, inProject: projectID)
                }
            )

        case .folder(let folder):
            let isExpanded = store.expandedFolderIDs.contains(folder.id)
            return AnyView(
                VStack(spacing: 0) {
                    sidebarRow(
                        entry: .folder(id: folder.id, projectID: projectID, name: folder.name),
                        disclosureIcon: "chevron.right",
                        rotatesDisclosureIcon: isExpanded,
                        secondaryIcon: "folder",
                        title: folder.name,
                        depth: depth,
                        selected: store.selectedFolderID == folder.id,
                        activity: SidebarRowActivity(
                            scope: .folder(folder.id),
                            isPresented: !isExpanded,
                            isVisible: isVisible
                        )
                    ) {
                        withAnimation(SidebarMotion.disclosure) {
                            store.selectFolder(withID: folder.id, inProject: projectID)
                            store.toggleFolder(withID: folder.id)
                        }
                    }

                    SidebarDisclosureSection(
                        isExpanded: isExpanded,
                        contentHeight: disclosureHeight(for: folder.children)
                    ) {
                        LazyVStack(spacing: 0) {
                            ForEach(folder.children) { child in
                                itemRow(
                                    child,
                                    projectID: projectID,
                                    depth: depth + 1,
                                    isVisible: isVisible && isExpanded
                                )
                            }
                        }
                    }
                }
            )
        }
    }

    @ViewBuilder
    private func sidebarRow(
        entry: SidebarEntry,
        disclosureIcon: String?,
        rotatesDisclosureIcon: Bool = false,
        secondaryIcon: String? = nil,
        title: String,
        depth: Int,
        selected: Bool,
        activity: SidebarRowActivity? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isRenaming = renamingEntry?.id == entry.id

        Group {
            if isRenaming {
                GeometryReader { geometry in
                    sidebarRowContent(
                        disclosureIcon: disclosureIcon,
                        rotatesDisclosureIcon: rotatesDisclosureIcon,
                        secondaryIcon: secondaryIcon,
                        depth: depth,
                        selected: selected,
                        availableWidth: geometry.size.width,
                        activity: activity
                    ) {
                        TextField("Name", text: $renameDraft)
                            .textFieldStyle(.plain)
                            .focused($focusedRenameID, equals: entry.id)
                            .onSubmit {
                                commitRename()
                            }
                            .onExitCommand {
                                cancelRename()
                            }
                    }
                }
                .frame(height: 28)
            } else {
                GeometryReader { geometry in
                    let rowButton = Button(action: action) {
                        sidebarRowContent(
                            disclosureIcon: disclosureIcon,
                            rotatesDisclosureIcon: rotatesDisclosureIcon,
                            secondaryIcon: secondaryIcon,
                            depth: depth,
                            selected: selected,
                            availableWidth: geometry.size.width,
                            activity: activity
                        ) {
                            Text(title)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(width: geometry.size.width, alignment: .leading)

                    if let activity {
                        AgentActivityAccessibleRow(
                            registry: agentActivity,
                            scope: activity.scope,
                            isPresented: activity.isPresented
                        ) {
                            rowButton
                        }
                    } else {
                        rowButton
                    }
                }
                .frame(height: 28)
            }
        }
        .contextMenu {
            creationActions(for: entry)
            paneActions(for: entry)
            if entry.canContainItems {
                Divider()
            }
            Button("Rename") {
                beginRename(entry)
            }
            Divider()
            Button("\(entry.removeLabel)...", role: .destructive) {
                pendingRemoval = entry
            }
        }
    }

    @ViewBuilder
    private func paneActions(for entry: SidebarEntry) -> some View {
        if case .note(let noteID, let projectID, _) = entry {
            Divider()
            Button("Open in Pane on Right") {
                store.openNoteInNewPane(
                    noteID: noteID,
                    inProjectWithID: projectID,
                    axis: .horizontal
                )
            }
            .disabled(!store.canAddPane(inProjectWithID: projectID))
            Button("Open in Pane Below") {
                store.openNoteInNewPane(
                    noteID: noteID,
                    inProjectWithID: projectID,
                    axis: .vertical
                )
            }
            .disabled(!store.canAddPane(inProjectWithID: projectID))
        }
    }

    @ViewBuilder
    private func creationActions(for entry: SidebarEntry) -> some View {
        switch entry {
        case .project(let projectID, _, _):
            Button("New Terminal Space") {
                store.addSpace(toFolderWithID: nil, inProjectWithID: projectID)
            }
            Button("New Note") {
                store.addNote(toFolderWithID: nil, inProjectWithID: projectID)
            }
            Button("New Folder Here") {
                store.addFolder(toFolderWithID: nil, inProjectWithID: projectID)
            }

        case .folder(let folderID, let projectID, _):
            Button("New Terminal Space") {
                store.addSpace(
                    toFolderWithID: folderID,
                    inProjectWithID: projectID
                )
            }
            Button("New Note") {
                store.addNote(
                    toFolderWithID: folderID,
                    inProjectWithID: projectID
                )
            }
            Button("New Folder Here") {
                store.addFolder(
                    toFolderWithID: folderID,
                    inProjectWithID: projectID
                )
            }

        case .note, .space:
            EmptyView()
        }
    }

    private func sidebarRowContent<Content: View>(
        disclosureIcon: String?,
        rotatesDisclosureIcon: Bool,
        secondaryIcon: String?,
        depth: Int,
        selected: Bool,
        availableWidth: CGFloat,
        activity: SidebarRowActivity?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let compactMetrics = availableWidth <= 180
        let iconWidth: CGFloat = compactMetrics ? 12 : 13
        let spacing: CGFloat = compactMetrics ? 5 : 7
        let leadingPadding = CGFloat(
            (compactMetrics ? 8 : 10) + depth * (compactMetrics ? 10 : 14)
        )
        let trailingPadding: CGFloat = compactMetrics ? 6 : 8

        return HStack(spacing: spacing) {
            if let disclosureIcon {
                Image(systemName: disclosureIcon)
                    .frame(width: iconWidth)
                    .rotationEffect(.degrees(rotatesDisclosureIcon ? 90 : 0))
            } else {
                Color.clear
                    .frame(width: iconWidth, height: iconWidth)
            }
            if let secondaryIcon {
                Image(systemName: secondaryIcon)
                    .frame(width: iconWidth)
            }
            content()
                .layoutPriority(-1)
            Spacer(minLength: 0)
            if let activity {
                AgentActivityStatusSlot(
                    registry: agentActivity,
                    scope: activity.scope,
                    isPresented: activity.isPresented,
                    isVisible: activity.isVisible,
                    selected: selected
                )
                .fixedSize()
                .layoutPriority(1)
            }
        }
        .font(.system(size: 12))
        .frame(
            width: max(availableWidth - leadingPadding - trailingPadding, 0),
            height: 28,
            alignment: .leading
        )
        .padding(.leading, leadingPadding)
        .padding(.trailing, trailingPadding)
        .clipped()
        .contentShape(Rectangle())
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    private func beginRename(_ entry: SidebarEntry) {
        renamingEntry = entry
        renameDraft = entry.name
        focusedRenameID = entry.id
    }

    private func commitRename() {
        guard let entry = renamingEntry else {
            return
        }
        let name = renameDraft
        renamingEntry = nil
        focusedRenameID = nil

        switch entry {
        case .project(let id, _, _):
            store.renameProject(withID: id, to: name)
        case .folder(let id, let projectID, _),
            .note(let id, let projectID, _),
            .space(let id, let projectID, _):
            store.renameItem(withID: id, inProject: projectID, to: name)
        }
    }

    private func cancelRename() {
        renamingEntry = nil
        focusedRenameID = nil
        renameDraft = ""
    }

    private func removePendingEntry() {
        guard let entry = pendingRemoval else {
            return
        }
        pendingRemoval = nil
        performRemoval(entry)
    }

    private func saveAndRemovePendingEntry() {
        guard let entry = pendingRemoval else {
            return
        }
        let paneIDs = paneIDs(affectedBy: entry)
        pendingRemoval = nil
        Task {
            do {
                try await editors.saveAllBuffers(inPaneIDs: paneIDs)
                performRemoval(entry)
            } catch {
                store.presentError(error.localizedDescription)
            }
        }
    }

    private func performRemoval(_ entry: SidebarEntry) {
        let removedNoteIDs: Set<UUID>
        switch entry {
        case .project(let id, _, _):
            removedNoteIDs = store.removeProject(withID: id)
        case .folder(let id, let projectID, _),
            .note(let id, let projectID, _),
            .space(let id, let projectID, _):
            removedNoteIDs = store.removeItem(withID: id, inProject: projectID)
        }
        notes.archive(noteIDs: removedNoteIDs)
    }

    private var pendingRemovalHasUnsavedChanges: Bool {
        guard let pendingRemoval else {
            return false
        }
        return editors.hasUnsavedChanges(
            inPaneIDs: paneIDs(affectedBy: pendingRemoval)
        )
    }

    private var pendingRemovalMessage: String {
        guard let pendingRemoval else {
            return ""
        }
        if pendingRemovalHasUnsavedChanges {
            return pendingRemoval.removalMessage
                + " One or more files in the affected IDE panes have unsaved changes."
        }
        return pendingRemoval.removalMessage
    }

    private func paneIDs(affectedBy entry: SidebarEntry) -> Set<UUID> {
        switch entry {
        case .project(let projectID, _, _):
            return store.terminalIDs(inProjectWithID: projectID)
        case .folder(let itemID, let projectID, _),
            .note(let itemID, let projectID, _),
            .space(let itemID, let projectID, _):
            return store.terminalIDs(
                inItemWithID: itemID,
                inProjectWithID: projectID
            )
        }
    }

    private func disclosureHeight(for items: [WorkspaceItem]) -> CGFloat {
        CGFloat(visibleRowCount(in: items)) * 28
    }

    private func visibleRowCount(in items: [WorkspaceItem]) -> Int {
        items.reduce(into: 0) { count, item in
            count += 1
            guard case .folder(let folder) = item,
                store.expandedFolderIDs.contains(folder.id)
            else {
                return
            }
            count += visibleRowCount(in: folder.children)
        }
    }
}

private struct SidebarRowActivity {
    let scope: AgentActivityScope
    let isPresented: Bool
    let isVisible: Bool
}

private enum SidebarEntry: Equatable {
    case project(id: UUID, name: String, kind: WorkspaceSectionKind)
    case folder(id: UUID, projectID: UUID, name: String)
    case note(id: UUID, projectID: UUID, name: String)
    case space(id: UUID, projectID: UUID, name: String)

    var id: UUID {
        switch self {
        case .project(let id, _, _),
            .folder(let id, _, _),
            .note(let id, _, _),
            .space(let id, _, _):
            id
        }
    }

    var name: String {
        switch self {
        case .project(_, let name, _),
            .folder(_, _, let name),
            .note(_, _, let name),
            .space(_, _, let name):
            name
        }
    }

    var removeLabel: String {
        switch self {
        case .project(_, _, let kind):
            kind == .folder ? "Remove Folder" : "Remove Project"
        case .folder:
            "Remove Folder"
        case .note:
            "Remove Note"
        case .space:
            "Remove Terminal Space"
        }
    }

    var canContainItems: Bool {
        switch self {
        case .project, .folder:
            true
        case .note, .space:
            false
        }
    }

    var removalTitle: String {
        "Remove \"\(name)\"?"
    }

    var removalMessage: String {
        switch self {
        case .project(_, _, let kind):
            if kind == .folder {
                "Everything inside this folder will be removed. Its running terminals will stop, and saved notes will move to Recently Deleted."
            } else {
                "Its terminal spaces and notes will be removed. Running terminals will stop, and saved notes will move to Recently Deleted."
            }
        case .folder:
            "Everything inside this folder will be removed. Its running terminals will stop, and saved notes will move to Recently Deleted."
        case .note:
            "Its saved text and drawing will be moved to Termuctive's Recently Deleted notes folder."
        case .space:
            "Its running terminals will stop."
        }
    }
}
