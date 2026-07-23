import SwiftUI

struct ProjectSidebar: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var editors: EditorSessionPool
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
                VStack(spacing: 0) {
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
                    && store.selectedFolderID == nil
            ) {
                if store.document.selectedProjectID == project.id {
                    withAnimation(SidebarMotion.disclosure) {
                        store.toggleProject(withID: project.id)
                    }
                } else {
                    store.selectProject(withID: project.id)
                }
            }

            SidebarDisclosureSection(isExpanded: isExpanded) {
                VStack(spacing: 0) {
                    ForEach(project.items) { item in
                        itemRow(item, projectID: project.id, depth: 1)
                    }
                }
            }
        }
    }

    private func itemRow(
        _ item: WorkspaceItem,
        projectID: UUID,
        depth: Int
    ) -> AnyView {
        switch item {
        case .space(let space):
            return AnyView(
                sidebarRow(
                    entry: .space(id: space.id, projectID: projectID, name: space.name),
                    disclosureIcon: nil,
                    secondaryIcon: "rectangle",
                    title: space.name,
                    depth: depth,
                    selected: store.document.selectedSpaceID == space.id
                        && store.selectedFolderID == nil
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
                        selected: store.selectedFolderID == folder.id
                    ) {
                        withAnimation(SidebarMotion.disclosure) {
                            store.selectFolder(withID: folder.id, inProject: projectID)
                            store.toggleFolder(withID: folder.id)
                        }
                    }

                    SidebarDisclosureSection(isExpanded: isExpanded) {
                        VStack(spacing: 0) {
                            ForEach(folder.children) { child in
                                itemRow(child, projectID: projectID, depth: depth + 1)
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
        action: @escaping () -> Void
    ) -> some View {
        let isRenaming = renamingEntry?.id == entry.id

        Group {
            if isRenaming {
                sidebarRowContent(
                    disclosureIcon: disclosureIcon,
                    rotatesDisclosureIcon: rotatesDisclosureIcon,
                    secondaryIcon: secondaryIcon,
                    depth: depth,
                    selected: selected
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
            } else {
                Button(action: action) {
                    sidebarRowContent(
                        disclosureIcon: disclosureIcon,
                        rotatesDisclosureIcon: rotatesDisclosureIcon,
                        secondaryIcon: secondaryIcon,
                        depth: depth,
                        selected: selected
                    ) {
                        Text(title)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu {
            creationActions(for: entry)
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
    private func creationActions(for entry: SidebarEntry) -> some View {
        switch entry {
        case .project(let projectID, _, _):
            Button("New Terminal Space") {
                store.addSpace(toFolderWithID: nil, inProjectWithID: projectID)
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
            Button("New Folder Here") {
                store.addFolder(
                    toFolderWithID: folderID,
                    inProjectWithID: projectID
                )
            }

        case .space:
            EmptyView()
        }
    }

    private func sidebarRowContent<Content: View>(
        disclosureIcon: String?,
        rotatesDisclosureIcon: Bool,
        secondaryIcon: String?,
        depth: Int,
        selected: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 7) {
            if let disclosureIcon {
                Image(systemName: disclosureIcon)
                    .frame(width: 13)
                    .rotationEffect(.degrees(rotatesDisclosureIcon ? 90 : 0))
            } else {
                Color.clear
                    .frame(width: 13, height: 13)
            }
            if let secondaryIcon {
                Image(systemName: secondaryIcon)
                    .frame(width: 13)
            }
            content()
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.leading, CGFloat(10 + depth * 14))
        .padding(.trailing, 8)
        .frame(height: 28)
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
        switch entry {
        case .project(let id, _, _):
            store.removeProject(withID: id)
        case .folder(let id, let projectID, _),
            .space(let id, let projectID, _):
            store.removeItem(withID: id, inProject: projectID)
        }
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
            .space(let itemID, let projectID, _):
            return store.terminalIDs(
                inItemWithID: itemID,
                inProjectWithID: projectID
            )
        }
    }
}

private enum SidebarEntry: Equatable {
    case project(id: UUID, name: String, kind: WorkspaceSectionKind)
    case folder(id: UUID, projectID: UUID, name: String)
    case space(id: UUID, projectID: UUID, name: String)

    var id: UUID {
        switch self {
        case .project(let id, _, _),
            .folder(let id, _, _),
            .space(let id, _, _):
            id
        }
    }

    var name: String {
        switch self {
        case .project(_, let name, _),
            .folder(_, _, let name),
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
        case .space:
            "Remove Terminal Space"
        }
    }

    var canContainItems: Bool {
        switch self {
        case .project, .folder:
            true
        case .space:
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
                "Everything inside this folder will be removed and its running terminals will stop."
            } else {
                "Its saved terminal spaces will be removed and their running terminals will stop."
            }
        case .folder:
            "Everything inside this folder will be removed and its running terminals will stop."
        case .space:
            "Its running terminals will stop."
        }
    }
}
