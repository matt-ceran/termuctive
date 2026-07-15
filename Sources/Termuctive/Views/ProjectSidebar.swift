import SwiftUI

struct ProjectSidebar: View {
    @ObservedObject var store: WorkspaceStore
    let chooseProject: () -> Void

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
                .accessibilityLabel("Add project item")

                Button {
                    store.isSidebarVisible = false
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
    }

    @ViewBuilder
    private func projectSection(_ project: TerminalProject) -> some View {
        sidebarRow(
            icon: "folder",
            title: project.name,
            depth: 0,
            selected: store.document.selectedProjectID == project.id
                && store.selectedFolderID == nil
        ) {
            store.selectProject(withID: project.id)
        }

        if store.document.selectedProjectID == project.id {
            ForEach(project.items) { item in
                itemRow(item, projectID: project.id, depth: 1)
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
                    icon: "rectangle",
                    title: space.name,
                    depth: depth,
                    selected: store.document.selectedSpaceID == space.id
                ) {
                    store.selectSpace(withID: space.id, inProject: projectID)
                }
            )

        case .folder(let folder):
            let isExpanded = store.expandedFolderIDs.contains(folder.id)
            return AnyView(
                VStack(spacing: 0) {
                    sidebarRow(
                        icon: isExpanded ? "chevron.down" : "chevron.right",
                        secondaryIcon: "folder",
                        title: folder.name,
                        depth: depth,
                        selected: store.selectedFolderID == folder.id
                    ) {
                        store.selectFolder(withID: folder.id, inProject: projectID)
                        store.toggleFolder(withID: folder.id)
                    }

                    if isExpanded {
                        ForEach(folder.children) { child in
                            itemRow(child, projectID: projectID, depth: depth + 1)
                        }
                    }
                }
            )
        }
    }

    private func sidebarRow(
        icon: String,
        secondaryIcon: String? = nil,
        title: String,
        depth: Int,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .frame(width: 13)
                if let secondaryIcon {
                    Image(systemName: secondaryIcon)
                        .frame(width: 13)
                }
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .padding(.leading, CGFloat(10 + depth * 14))
            .padding(.trailing, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}
