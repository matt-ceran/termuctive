import Foundation

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var document: WorkspaceDocument
    @Published private(set) var focusedPaneID: UUID?
    @Published private(set) var zoomedPaneID: UUID?
    @Published private(set) var expandedProjectIDs: Set<UUID> = []
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
        guard let focusedPaneID else {
            return false
        }
        return selectedSpace?.layout.terminalIDs.contains(focusedPaneID) == true
    }

    var canCyclePanes: Bool {
        (selectedSpace?.layout.terminalCount ?? 0) > 1
    }

    var canCycleSpaces: Bool {
        (selectedProject?.terminalSpaces.count ?? 0) > 1
    }

    var canCycleProjects: Bool {
        document.projects.count > 1
    }

    var canZoomFocusedPane: Bool {
        canCyclePanes && focusedPaneID != nil
    }

    var isFocusedPaneZoomed: Bool {
        zoomedPaneID != nil
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
        expandedProjectIDs.insert(project.id)
        selectedFolderID = nil
        focusedPaneID = pane.id
        zoomedPaneID = nil
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
        expandedProjectIDs.insert(projectID)
        expandedFolderIDs.formUnion(
            document.projects[projectIndex].ancestorFolderIDs(forSpaceWithID: id)
        )
        selectedFolderID = nil
        focusedPaneID = space.layout.firstTerminalID
        zoomedPaneID = nil
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

    func toggleProject(withID id: UUID) {
        guard document.projects.contains(where: { $0.id == id }) else {
            return
        }
        if expandedProjectIDs.contains(id) {
            expandedProjectIDs.remove(id)
        } else {
            expandedProjectIDs.insert(id)
        }
    }

    func focusNextPane() {
        focusAdjacentPane(offset: 1)
    }

    func focusPreviousPane() {
        focusAdjacentPane(offset: -1)
    }

    func selectNextSpace() {
        selectAdjacentSpace(offset: 1)
    }

    func selectPreviousSpace() {
        selectAdjacentSpace(offset: -1)
    }

    func selectNextProject() {
        selectAdjacentProject(offset: 1)
    }

    func selectPreviousProject() {
        selectAdjacentProject(offset: -1)
    }

    func toggleFocusedPaneZoom() {
        guard canZoomFocusedPane,
            let focusedPaneID
        else {
            return
        }
        zoomedPaneID = zoomedPaneID == focusedPaneID ? nil : focusedPaneID
    }

    func addFolder() {
        guard let project = selectedProject else {
            return
        }

        addFolder(
            toFolderWithID: validSelectedFolderID(in: project),
            inProjectWithID: project.id
        )
    }

    func addFolder(toFolderWithID parentID: UUID?, inProjectWithID projectID: UUID) {
        guard let projectIndex = document.projects.firstIndex(where: { $0.id == projectID }) else {
            return
        }
        let project = document.projects[projectIndex]
        guard parentID.map({ project.containsFolder(withID: $0) }) ?? true else {
            return
        }

        let existingNames =
            project.childNames(
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

        activateProject(at: projectIndex)
        selectedFolderID = folder.id
        if let parentID {
            expandedFolderIDs.insert(parentID)
        }
        expandedFolderIDs.insert(folder.id)
        save()
    }

    func addSpace() {
        guard let project = selectedProject else {
            return
        }

        addSpace(
            toFolderWithID: validSelectedFolderID(in: project),
            inProjectWithID: project.id
        )
    }

    func addSpace(toFolderWithID parentID: UUID?, inProjectWithID projectID: UUID) {
        guard let projectIndex = document.projects.firstIndex(where: { $0.id == projectID }) else {
            return
        }
        let project = document.projects[projectIndex]
        guard parentID.map({ project.containsFolder(withID: $0) }) ?? true else {
            return
        }

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
        document.selectedProjectID = projectID
        document.selectedSpaceID = space.id
        expandedProjectIDs.insert(projectID)
        if let parentID {
            expandedFolderIDs.insert(parentID)
        }
        selectedFolderID = nil
        focusedPaneID = pane.id
        zoomedPaneID = nil
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
        expandedProjectIDs.formIntersection(document.projects.map(\.id))
        expandedFolderIDs.formIntersection(document.folderIDs)

        if wasSelected {
            selectedFolderID = nil
            guard !document.projects.isEmpty else {
                document.selectedProjectID = nil
                document.selectedSpaceID = nil
                focusedPaneID = nil
                zoomedPaneID = nil
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
        normalizeZoom()
        save()
    }

    func focusPane(withID id: UUID) {
        guard selectedSpace?.layout.terminalIDs.contains(id) == true else {
            return
        }
        focusedPaneID = id
        if zoomedPaneID != nil {
            zoomedPaneID = id
        }
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
        zoomedPaneID = nil
        save()
    }

    func preparePDFPane(
        fromPaneID sourcePaneID: UUID,
        placement: PDFPanePlacement
    ) -> UUID? {
        guard let selectedSpace,
            selectedSpace.layout.terminalIDs.contains(sourcePaneID),
            let sourcePane = selectedSpace.layout.terminal(withID: sourcePaneID)
        else {
            return nil
        }

        let orderedPaneIDs = selectedSpace.layout.orderedTerminalIDs
        if orderedPaneIDs.count > 1 {
            zoomedPaneID = nil
            switch placement {
            case .left:
                return orderedPaneIDs.first
            case .right:
                return orderedPaneIDs.last
            case .automatic:
                guard let sourceIndex = orderedPaneIDs.firstIndex(of: sourcePaneID) else {
                    return orderedPaneIDs.last
                }
                return sourceIndex < orderedPaneIDs.count / 2
                    ? orderedPaneIDs.last
                    : orderedPaneIDs.first
            }
        }

        let resolvedPlacement: PaneInsertionPlacement =
            placement == .left ? .before : .after
        let previewPane = TerminalPane(
            title: defaultShellName,
            workingDirectory: sourcePane.workingDirectory
        )
        updateSelectedSpace { space in
            guard
                let layout = space.layout.splittingTerminal(
                    withID: sourcePaneID,
                    axis: .horizontal,
                    newPane: previewPane,
                    placement: resolvedPlacement
                )
            else {
                return
            }
            space.layout = layout
        }
        focusedPaneID = sourcePaneID
        zoomedPaneID = nil
        save()
        return previewPane.id
    }

    func pdfSearchRoots(forPaneID paneID: UUID) -> [URL] {
        guard let pane = document.terminal(withID: paneID),
            let project = document.project(containingTerminalWithID: paneID)
        else {
            return []
        }
        return [pane.workingDirectory, project.rootDirectory].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    func closeFocusedPane() {
        guard let focusedPaneID else {
            return
        }

        closePane(withID: focusedPaneID)
    }

    func closePane(withID paneID: UUID) {
        guard let projectID = selectedProject?.id,
            let space = selectedSpace,
            space.layout.terminalIDs.contains(paneID)
        else {
            return
        }

        if space.layout.terminalCount == 1 {
            removeItem(withID: space.id, inProject: projectID)
            return
        }

        updateSelectedSpace { space in
            guard let layout = space.layout.removingTerminal(withID: paneID) else {
                return
            }
            space.layout = layout
        }
        zoomedPaneID = nil
        let focusedPaneRemains =
            focusedPaneID.map {
                selectedSpace?.layout.terminalIDs.contains($0) == true
            } ?? false
        if !focusedPaneRemains {
            focusedPaneID = selectedSpace?.layout.firstTerminalID
        }
        save()
    }

    func commitSplitRatio(splitID: UUID, ratio: Double) {
        updateSelectedSpace { space in
            space.layout = space.layout.settingRatio(forSplitID: splitID, to: ratio)
        }
        save()
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

    func presentError(_ message: String) {
        errorMessage = message
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
        zoomedPaneID = nil
        document.selectedProjectID = document.projects[index].id
        expandedProjectIDs.insert(document.projects[index].id)
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
        if let space {
            expandedFolderIDs.formUnion(
                project.ancestorFolderIDs(forSpaceWithID: space.id)
            )
        }

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

    private func focusAdjacentPane(offset: Int) {
        guard let layout = selectedSpace?.layout,
            let paneID = adjacentID(
                in: layout.orderedTerminalIDs,
                currentID: focusedPaneID,
                offset: offset
            )
        else {
            return
        }
        focusedPaneID = paneID
        if zoomedPaneID != nil {
            zoomedPaneID = paneID
        }
    }

    private func selectAdjacentSpace(offset: Int) {
        guard let project = selectedProject,
            let spaceID = adjacentID(
                in: project.terminalSpaces.map(\.id),
                currentID: document.selectedSpaceID,
                offset: offset
            )
        else {
            return
        }
        selectSpace(withID: spaceID, inProject: project.id)
    }

    private func selectAdjacentProject(offset: Int) {
        guard
            let projectID = adjacentID(
                in: document.projects.map(\.id),
                currentID: document.selectedProjectID,
                offset: offset
            )
        else {
            return
        }
        selectProject(withID: projectID)
    }

    private func adjacentID(in ids: [UUID], currentID: UUID?, offset: Int) -> UUID? {
        guard ids.count > 1 else {
            return nil
        }
        guard let currentID,
            let currentIndex = ids.firstIndex(of: currentID)
        else {
            return offset > 0 ? ids.first : ids.last
        }
        return ids[(currentIndex + offset + ids.count) % ids.count]
    }

    private func normalizeZoom() {
        guard let zoomedPaneID,
            selectedSpace?.layout.terminalIDs.contains(zoomedPaneID) != true
        else {
            return
        }
        self.zoomedPaneID = nil
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
