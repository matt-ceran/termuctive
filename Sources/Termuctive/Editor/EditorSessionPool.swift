import Foundation

@MainActor
final class EditorPaneSession: ObservableObject, Identifiable {
    let id: UUID
    let rootURL: URL

    @Published private(set) var fileTree = EditorFileTreeSnapshot(
        nodes: [],
        isTruncated: false
    )
    @Published private(set) var buffers: [EditorDocumentBuffer] = []
    @Published private(set) var selectedBufferID: UUID?
    @Published private(set) var isRefreshingFileTree = false
    @Published private(set) var errorMessage: String?
    @Published var isNavigatorVisible = true
    @Published var searchText = ""
    @Published var pendingCloseBufferID: UUID?

    private var watcher: ProjectFileWatcher?
    private var eventRefreshTask: Task<Void, Never>?
    private var treeRefreshGeneration = 0

    init(paneID: UUID, rootURL: URL) {
        id = paneID
        self.rootURL = rootURL.standardizedFileURL
        startWatching()
        refreshFileTree()
    }

    var selectedBuffer: EditorDocumentBuffer? {
        guard let selectedBufferID else {
            return nil
        }
        return buffers.first { $0.id == selectedBufferID }
    }

    var hasUnsavedChanges: Bool {
        buffers.contains { $0.hasUncommittedChanges }
    }

    func openFile(_ url: URL, collapseNavigator: Bool = false) async {
        let standardizedURL = url.standardizedFileURL
        guard isInsideRoot(standardizedURL) else {
            errorMessage = "Termuctive only opens files inside this project."
            return
        }
        if let existing = buffers.first(where: { $0.url == standardizedURL }) {
            selectedBufferID = existing.id
            if collapseNavigator {
                isNavigatorVisible = false
            }
            return
        }

        do {
            let buffer = try await EditorDocumentBuffer.open(url: standardizedURL)
            buffers.append(buffer)
            selectedBufferID = buffer.id
            errorMessage = nil
            if collapseNavigator {
                isNavigatorVisible = false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectBuffer(withID id: UUID) {
        guard buffers.contains(where: { $0.id == id }) else {
            return
        }
        selectedBufferID = id
    }

    func requestCloseBuffer(withID id: UUID) {
        guard let buffer = buffers.first(where: { $0.id == id }) else {
            return
        }
        if buffer.isDirty {
            pendingCloseBufferID = id
        } else {
            closeBuffer(withID: id)
        }
    }

    func cancelPendingBufferClose() {
        pendingCloseBufferID = nil
    }

    func discardAndClosePendingBuffer() {
        guard let pendingCloseBufferID else {
            return
        }
        self.pendingCloseBufferID = nil
        closeBuffer(withID: pendingCloseBufferID)
    }

    func saveAndClosePendingBuffer() async {
        guard let pendingCloseBufferID,
            let buffer = buffers.first(where: { $0.id == pendingCloseBufferID })
        else {
            return
        }
        do {
            try await buffer.save()
            self.pendingCloseBufferID = nil
            closeBuffer(withID: pendingCloseBufferID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveSelectedBuffer() async {
        guard let selectedBuffer else {
            return
        }
        do {
            try await selectedBuffer.save()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveAllBuffers() async throws {
        for buffer in buffers {
            while buffer.hasUncommittedChanges {
                try await buffer.save()
            }
        }
        errorMessage = nil
    }

    func dismissError() {
        errorMessage = nil
    }

    func refreshFileTree() {
        treeRefreshGeneration &+= 1
        let generation = treeRefreshGeneration
        let projectRoot = rootURL
        isRefreshingFileTree = true
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result {
                    try EditorFileTreeBuilder.build(rootURL: projectRoot)
                }
            }.value
            guard let self, treeRefreshGeneration == generation else {
                return
            }
            isRefreshingFileTree = false
            switch result {
            case .success(let tree):
                fileTree = tree
                errorMessage = nil
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    func stop() {
        eventRefreshTask?.cancel()
        eventRefreshTask = nil
        watcher?.stop()
        watcher = nil
    }

    private func closeBuffer(withID id: UUID) {
        guard let index = buffers.firstIndex(where: { $0.id == id }) else {
            return
        }
        let wasSelected = selectedBufferID == id
        buffers.remove(at: index)
        guard wasSelected else {
            return
        }
        if buffers.indices.contains(index) {
            selectedBufferID = buffers[index].id
        } else {
            selectedBufferID = buffers.last?.id
        }
    }

    private func startWatching() {
        watcher = ProjectFileWatcher(rootURL: rootURL) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleFileSystemEvent()
            }
        }
    }

    private func handleFileSystemEvent() {
        eventRefreshTask?.cancel()
        eventRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled else {
                return
            }
            for buffer in buffers {
                await buffer.refreshFromDisk()
            }
            guard !Task.isCancelled else {
                return
            }
            refreshFileTree()
        }
    }

    private func isInsideRoot(_ url: URL) -> Bool {
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedCandidate = url.resolvingSymlinksInPath().standardizedFileURL.path
        return resolvedCandidate == resolvedRoot
            || resolvedCandidate.hasPrefix(resolvedRoot + "/")
    }
}

@MainActor
final class EditorSessionPool: ObservableObject {
    @Published private(set) var presentedPaneIDs: Set<UUID> = []
    @Published var pendingClosePaneID: UUID?

    private let store: WorkspaceStore
    private var sessions: [UUID: EditorPaneSession] = [:]

    init(store: WorkspaceStore) {
        self.store = store
    }

    func isEditorPresented(inPaneID paneID: UUID) -> Bool {
        presentedPaneIDs.contains(paneID)
    }

    func session(forPaneID paneID: UUID) -> EditorPaneSession? {
        guard isEditorPresented(inPaneID: paneID) else {
            return nil
        }
        return sessions[paneID]
    }

    func retainedSession(forPaneID paneID: UUID) -> EditorPaneSession? {
        sessions[paneID]
    }

    var hasUnsavedChanges: Bool {
        sessions.values.contains { $0.hasUnsavedChanges }
    }

    func hasUnsavedChanges(inPaneIDs paneIDs: Set<UUID>) -> Bool {
        paneIDs.contains { sessions[$0]?.hasUnsavedChanges == true }
    }

    func saveAllBuffers() async throws {
        try await saveAllBuffers(inPaneIDs: Set(sessions.keys))
    }

    func saveAllBuffers(inPaneIDs paneIDs: Set<UUID>) async throws {
        for paneID in paneIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            try await sessions[paneID]?.saveAllBuffers()
        }
    }

    func presentEditor(inPaneID paneID: UUID) {
        guard let rootURL = store.projectRootURL(forPaneID: paneID) else {
            store.presentError("Termuctive could not identify this pane's project directory.")
            return
        }

        if sessions[paneID]?.rootURL != rootURL.standardizedFileURL {
            sessions.removeValue(forKey: paneID)?.stop()
            sessions[paneID] = EditorPaneSession(
                paneID: paneID,
                rootURL: rootURL
            )
        }
        presentedPaneIDs.insert(paneID)
        store.focusPane(withID: paneID)
    }

    func dismissEditor(inPaneID paneID: UUID) {
        presentedPaneIDs.remove(paneID)
        store.focusPane(withID: paneID)
    }

    func requestClosePane(withID paneID: UUID) {
        guard store.selectedSpace?.layout.terminalIDs.contains(paneID) == true else {
            return
        }
        if sessions[paneID]?.hasUnsavedChanges == true {
            pendingClosePaneID = paneID
            return
        }
        removeSession(forPaneID: paneID)
        store.closePane(withID: paneID)
    }

    func cancelPendingPaneClose() {
        pendingClosePaneID = nil
    }

    func discardAndClosePendingPane() {
        guard let pendingClosePaneID else {
            return
        }
        self.pendingClosePaneID = nil
        removeSession(forPaneID: pendingClosePaneID)
        store.closePane(withID: pendingClosePaneID)
    }

    func saveAndClosePendingPane() async {
        guard let pendingClosePaneID,
            let session = sessions[pendingClosePaneID]
        else {
            return
        }
        do {
            try await session.saveAllBuffers()
            self.pendingClosePaneID = nil
            removeSession(forPaneID: pendingClosePaneID)
            store.closePane(withID: pendingClosePaneID)
        } catch {
            store.presentError(error.localizedDescription)
        }
    }

    func reconcile(validPaneIDs: Set<UUID>) {
        let removedPaneIDs = Set(sessions.keys).subtracting(validPaneIDs)
        for paneID in removedPaneIDs {
            removeSession(forPaneID: paneID)
        }
        presentedPaneIDs.formIntersection(validPaneIDs)
        if let pendingClosePaneID, !validPaneIDs.contains(pendingClosePaneID) {
            self.pendingClosePaneID = nil
        }
    }

    func terminateAll() {
        for session in sessions.values {
            session.stop()
        }
        sessions.removeAll()
        presentedPaneIDs.removeAll()
        pendingClosePaneID = nil
    }

    private func removeSession(forPaneID paneID: UUID) {
        sessions.removeValue(forKey: paneID)?.stop()
        presentedPaneIDs.remove(paneID)
    }
}
