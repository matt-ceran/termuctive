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
            name: uniqueName(
                base: url.lastPathComponent,
                existing: document.projects.map(\.name)
            ),
            rootDirectory: path,
            items: [.space(space)],
            lastSelectedSpaceID: space.id
        )

        document.projects.append(project)
        document.selectedProjectID = project.id
        document.selectedSpaceID = space.id
        selectedFolderID = nil
        focusedPaneID = pane.id
        save()
    }

    func selectProject(withID id: UUID) {
        guard let projectIndex = document.projects.firstIndex(where: { $0.id == id }) else {
            return
        }

        activateProject(at: projectIndex)
        selectedFolderID = nil
        save()
    }

    func selectSpace(withID id: UUID, inProject projectID: UUID) {
        guard
            let projectIndex = document.projects.firstIndex(where: { $0.id == projectID }),
            let space = document.projects[projectIndex].space(withID: id)
        else {
            return
        }

        document.projects[projectIndex].lastSelectedSpaceID = id
        document.selectedProjectID = projectID
        document.selectedSpaceID = id
        selectedFolderID = nil
        focusedPaneID = space.layout.firstTerminalID
        save()
    }

    func selectFolder(withID id: UUID, inProject projectID: UUID) {
        guard
            let projectIndex = document.projects.firstIndex(where: { $0.id == projectID }),
            document.projects[projectIndex].containsFolder(withID: id)
        else {
            return
        }

        let projectChanged = document.selectedProjectID != projectID
        if projectChanged {
            activateProject(at: projectIndex)
        }
        selectedFolderID = id
        if projectChanged {
            save()
        }
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

        let parentID = validSelectedFolderID(in: document.projects[projectIndex])
        let existingNames =
            document.projects[projectIndex].childNames(
                inFolderWithID: parentID
            ) ?? []
        let folder = WorkspaceFolder(
            name: uniqueName(base: "Folder", existing: existingNames)
        )
        guard
            document.projects[projectIndex].append(
                .folder(folder),
                toFolderWithID: parentID
            )
        else {
            return
        }

        selectedFolderID = folder.id
        if let parentID {
            expandedFolderIDs.insert(parentID)
        }
        expandedFolderIDs.insert(folder.id)
        save()
    }

    func addSpace() {
        guard let projectIndex = selectedProjectIndex else {
            return
        }

        let project = document.projects[projectIndex]
        let parentID = validSelectedFolderID(in: project)
        let existingNames = project.childNames(inFolderWithID: parentID) ?? []
        let pane = TerminalPane(
            title: defaultShellName,
            workingDirectory: project.rootDirectory
        )
        let space = TerminalSpace(
            name: uniqueName(base: "Terminal", existing: existingNames),
            layout: .terminal(pane)
        )
        guard
            document.projects[projectIndex].append(
                .space(space),
                toFolderWithID: parentID
            )
        else {
            return
        }

        document.projects[projectIndex].lastSelectedSpaceID = space.id
        document.selectedSpaceID = space.id
        if let parentID {
            expandedFolderIDs.insert(parentID)
        }
        selectedFolderID = nil
        focusedPaneID = pane.id
        save()
    }

    func renameProject(withID id: UUID, to proposedName: String) {
        guard let projectIndex = document.projects.firstIndex(where: { $0.id == id }),
            let baseName = normalizedName(proposedName)
        else {
            return
        }
        let existingNames = document.projects.filter { $0.id != id }.map(\.name)
        let name = uniqueName(base: baseName, existing: existingNames)
        guard document.projects[projectIndex].name != name else {
            return
        }

        document.projects[projectIndex].name = name
        save()
    }

    func renameItem(withID id: UUID, inProject projectID: UUID, to proposedName: String) {
        guard
            let projectIndex = document.projects.firstIndex(where: { $0.id == projectID }),
            let baseName = normalizedName(proposedName),
            let existingNames = document.projects[projectIndex].siblingNames(
                forItemWithID: id
            )
        else {
            return
        }
        let name = uniqueName(base: baseName, existing: existingNames)
        guard document.projects[projectIndex].renameItem(withID: id, to: name) else {
            return
        }
        save()
    }

    func removeProject(withID id: UUID) {
        guard let projectIndex = document.projects.firstIndex(where: { $0.id == id }) else {
            return
        }
        let wasSelected = document.selectedProjectID == id
        document.projects.remove(at: projectIndex)
        expandedFolderIDs.formIntersection(document.folderIDs)

        if wasSelected {
            selectedFolderID = nil
            guard !document.projects.isEmpty else {
                document.selectedProjectID = nil
                document.selectedSpaceID = nil
                focusedPaneID = nil
                save()
                return
            }
            activateProject(at: min(projectIndex, document.projects.count - 1))
        }
        save()
    }

    func removeItem(withID id: UUID, inProject projectID: UUID) {
        guard let projectIndex = document.projects.firstIndex(where: { $0.id == projectID }),
            document.projects[projectIndex].removeItem(withID: id) != nil
        else {
            return
        }

        normalizeLastSelectedSpace(forProjectAt: projectIndex)
        expandedFolderIDs.formIntersection(document.folderIDs)
        if let selectedFolderID,
            !document.projects.contains(where: { $0.containsFolder(withID: selectedFolderID) })
        {
            self.selectedFolderID = nil
        }

        if document.selectedProjectID == projectID {
            restoreActiveSpace(
                inProjectAt: projectIndex,
                preferredSpaceID: document.selectedSpaceID
            )
        }
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

    private func activateProject(at index: Int, preferredSpaceID: UUID? = nil) {
        document.selectedProjectID = document.projects[index].id
        restoreActiveSpace(
            inProjectAt: index,
            preferredSpaceID: preferredSpaceID
                ?? document.projects[index].lastSelectedSpaceID
        )
    }

    private func restoreActiveSpace(inProjectAt index: Int, preferredSpaceID: UUID?) {
        let project = document.projects[index]
        let space =
            preferredSpaceID.flatMap { project.space(withID: $0) }
            ?? project.preferredSpace
        document.projects[index].lastSelectedSpaceID = space?.id
        document.selectedSpaceID = space?.id

        if let focusedPaneID,
            space?.layout.terminalIDs.contains(focusedPaneID) == true
        {
            return
        }
        focusedPaneID = space?.layout.firstTerminalID
    }

    private func normalizeLastSelectedSpace(forProjectAt index: Int) {
        let project = document.projects[index]
        guard let lastSelectedSpaceID = project.lastSelectedSpaceID,
            project.space(withID: lastSelectedSpaceID) != nil
        else {
            document.projects[index].lastSelectedSpaceID = project.firstSpace?.id
            return
        }
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
        for index in document.projects.indices {
            normalizeLastSelectedSpace(forProjectAt: index)
        }

        guard !document.projects.isEmpty else {
            document.selectedProjectID = nil
            document.selectedSpaceID = nil
            focusedPaneID = nil
            return
        }

        let projectIndex =
            document.projects.firstIndex {
                $0.id == document.selectedProjectID
            } ?? 0
        activateProject(
            at: projectIndex,
            preferredSpaceID: document.selectedSpaceID
        )
    }

    private func normalizedName(_ name: String) -> String? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func uniqueName(base: String, existing: [String]) -> String {
        let names = Set(existing.map { $0.lowercased() })
        guard names.contains(base.lowercased()) else {
            return base
        }

        var suffix = 2
        while names.contains("\(base) \(suffix)".lowercased()) {
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
