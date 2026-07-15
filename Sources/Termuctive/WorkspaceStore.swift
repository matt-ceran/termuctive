import Foundation

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var document: WorkspaceDocument
    @Published private(set) var focusedPaneID: UUID?
    @Published private(set) var expandedFolderIDs: Set<UUID> = []
    @Published private(set) var selectedFolderID: UUID?
    @Published private(set) var errorMessage: String?
    @Published var isSidebarVisible = true

    private let persistence: any WorkspacePersisting

    init(persistence: any WorkspacePersisting = WorkspaceFileStore.live) {
        self.persistence = persistence
        do {
            document = try persistence.load() ?? WorkspaceDocument()
        } catch {
            document = WorkspaceDocument()
            errorMessage = error.localizedDescription
        }
        normalizeSelection()
    }

    var selectedProject: TerminalProject? {
        document.selectedProject
    }

    var selectedSpace: TerminalSpace? {
        document.selectedSpace
    }

    var canCloseFocusedPane: Bool {
        (selectedSpace?.layout.terminalCount ?? 0) > 1 && focusedPaneID != nil
    }

    func addProject(at url: URL) {
        let path = url.standardizedFileURL.path
        if let existing = document.projects.first(where: { $0.rootDirectory == path }) {
            selectProject(withID: existing.id)
            return
        }

        let pane = TerminalPane(
            title: defaultShellName,
            workingDirectory: path
        )
        let space = TerminalSpace(
            name: "Terminal",
            layout: .terminal(pane)
        )
        let project = TerminalProject(
            name: url.lastPathComponent,
            rootDirectory: path,
            items: [.space(space)]
        )

        document.projects.append(project)
        document.selectedProjectID = project.id
        document.selectedSpaceID = space.id
        selectedFolderID = nil
        focusedPaneID = pane.id
        save()
    }

    func selectProject(withID id: UUID) {
        guard let project = document.projects.first(where: { $0.id == id }) else {
            return
        }

        document.selectedProjectID = id
        document.selectedSpaceID = project.firstSpace?.id
        selectedFolderID = nil
        focusedPaneID = project.firstSpace?.layout.firstTerminalID
        save()
    }

    func selectSpace(withID id: UUID, inProject projectID: UUID) {
        guard let project = document.projects.first(where: { $0.id == projectID }),
            let space = project.space(withID: id)
        else {
            return
        }

        document.selectedProjectID = projectID
        document.selectedSpaceID = id
        selectedFolderID = nil
        focusedPaneID = space.layout.firstTerminalID
        save()
    }

    func selectFolder(withID id: UUID, inProject projectID: UUID) {
        guard let project = document.projects.first(where: { $0.id == projectID }),
            project.containsFolder(withID: id)
        else {
            return
        }

        document.selectedProjectID = projectID
        selectedFolderID = id
    }

    func toggleFolder(withID id: UUID) {
        if expandedFolderIDs.contains(id) {
            expandedFolderIDs.remove(id)
        } else {
            expandedFolderIDs.insert(id)
        }
    }

    func addFolder() {
        guard let projectIndex = selectedProjectIndex else {
            return
        }

        let name = uniqueName(
            base: "Folder",
            existing: document.projects[projectIndex].items.map(\.name)
        )
        let folder = WorkspaceFolder(name: name)
        let parentID = validSelectedFolderID(in: document.projects[projectIndex])
        guard
            document.projects[projectIndex].append(
                .folder(folder),
                toFolderWithID: parentID
            )
        else {
            return
        }

        selectedFolderID = folder.id
        expandedFolderIDs.insert(folder.id)
        save()
    }

    func addSpace() {
        guard let projectIndex = selectedProjectIndex else {
            return
        }

        let project = document.projects[projectIndex]
        let name = uniqueName(
            base: "Terminal",
            existing: project.items.map(\.name)
        )
        let pane = TerminalPane(
            title: defaultShellName,
            workingDirectory: project.rootDirectory
        )
        let space = TerminalSpace(name: name, layout: .terminal(pane))
        let parentID = validSelectedFolderID(in: project)
        guard
            document.projects[projectIndex].append(
                .space(space),
                toFolderWithID: parentID
            )
        else {
            return
        }

        document.selectedSpaceID = space.id
        focusedPaneID = pane.id
        save()
    }

    func focusPane(withID id: UUID) {
        guard selectedSpace?.layout.terminalIDs.contains(id) == true else {
            return
        }
        focusedPaneID = id
    }

    func splitFocusedPane(axis: PaneAxis) {
        guard let focusedPaneID,
            let selectedSpace,
            let pane = selectedSpace.layout.terminal(withID: focusedPaneID)
        else {
            return
        }

        let newPane = TerminalPane(
            title: defaultShellName,
            workingDirectory: pane.workingDirectory
        )
        updateSelectedSpace { space in
            guard
                let layout = space.layout.splittingTerminal(
                    withID: focusedPaneID,
                    axis: axis,
                    newPane: newPane
                )
            else {
                return
            }
            space.layout = layout
        }
        self.focusedPaneID = newPane.id
        save()
    }

    func closeFocusedPane() {
        guard canCloseFocusedPane,
            let focusedPaneID
        else {
            return
        }

        updateSelectedSpace { space in
            guard let layout = space.layout.removingTerminal(withID: focusedPaneID) else {
                return
            }
            space.layout = layout
        }
        self.focusedPaneID = selectedSpace?.layout.firstTerminalID
        save()
    }

    func setSplitRatio(splitID: UUID, ratio: Double, persist: Bool) {
        updateSelectedSpace { space in
            space.layout = space.layout.settingRatio(forSplitID: splitID, to: ratio)
        }
        if persist {
            save()
        }
    }

    func updateTerminal(
        paneID: UUID,
        title: String? = nil,
        workingDirectory: String? = nil
    ) {
        guard let terminal = document.terminal(withID: paneID) else {
            return
        }
        let titleChanged = title.map { !$0.isEmpty && $0 != terminal.title } ?? false
        let directoryChanged =
            workingDirectory.map {
                !$0.isEmpty && $0 != terminal.workingDirectory
            } ?? false
        guard titleChanged || directoryChanged else {
            return
        }

        if document.updateTerminal(
            withID: paneID,
            title: title,
            workingDirectory: workingDirectory
        ) {
            save()
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private var selectedProjectIndex: Int? {
        guard let selectedProjectID = document.selectedProjectID else {
            return nil
        }
        return document.projects.firstIndex { $0.id == selectedProjectID }
    }

    private var defaultShellName: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return URL(fileURLWithPath: shell).lastPathComponent
    }

    private func validSelectedFolderID(in project: TerminalProject) -> UUID? {
        guard let selectedFolderID,
            project.containsFolder(withID: selectedFolderID)
        else {
            return nil
        }
        return selectedFolderID
    }

    private func updateSelectedSpace(_ update: (inout TerminalSpace) -> Void) {
        guard let projectIndex = selectedProjectIndex,
            let selectedSpaceID = document.selectedSpaceID
        else {
            return
        }
        _ = document.projects[projectIndex].updateSpace(
            withID: selectedSpaceID,
            update: update
        )
    }

    private func normalizeSelection() {
        guard !document.projects.isEmpty else {
            document.selectedProjectID = nil
            document.selectedSpaceID = nil
            focusedPaneID = nil
            return
        }

        let project =
            document.selectedProject
            ?? document.projects[0]
        document.selectedProjectID = project.id

        let space =
            document.selectedSpace
            ?? project.firstSpace
        document.selectedSpaceID = space?.id
        focusedPaneID = space?.layout.firstTerminalID
    }

    private func uniqueName(base: String, existing: [String]) -> String {
        let names = Set(existing)
        guard names.contains(base) else {
            return base
        }

        var suffix = 2
        while names.contains("\(base) \(suffix)") {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    private func save() {
        do {
            try persistence.save(document)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
