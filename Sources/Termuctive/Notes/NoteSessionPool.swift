import Foundation

@MainActor
final class NoteDocumentSession: ObservableObject, Identifiable {
    private static let autosaveDelay: UInt64 = 600_000_000
    private static let retryDelay: UInt64 = 1_000_000_000

    let id: UUID

    @Published private(set) var document: NoteDocument
    @Published private(set) var isDirty = false
    @Published private(set) var isSaving = false
    @Published private(set) var lastSavedAt: Date?
    @Published private(set) var errorMessage: String?
    private(set) var isStopped = false

    private let persistence: any NotePersisting
    private var autosaveTask: Task<Void, Never>?

    init(noteID: UUID, persistence: any NotePersisting) {
        id = noteID
        self.persistence = persistence
        do {
            let loadedDocument = try persistence.load(noteID: noteID)
            document = loadedDocument ?? NoteDocument(noteID: noteID)
            lastSavedAt = loadedDocument?.updatedAt
        } catch {
            document = NoteDocument(noteID: noteID)
            errorMessage = error.localizedDescription
        }
    }

    var canSave: Bool {
        isDirty && !isSaving
    }

    func updateRichText(_ data: Data) {
        guard !isStopped,
            document.richTextRTF != data
        else {
            return
        }
        document.richTextRTF = data
        markDirty()
    }

    func updateDrawing(_ drawing: NoteDrawing) {
        guard !isStopped,
            document.drawing != drawing
        else {
            return
        }
        document.drawing = drawing
        markDirty()
    }

    func updateWorkspaceMode(_ mode: NoteWorkspaceMode) {
        guard !isStopped,
            document.workspaceMode != mode
        else {
            return
        }
        document.workspaceMode = mode
        markDirty()
    }

    func saveNow() throws {
        guard !isStopped else {
            return
        }
        autosaveTask?.cancel()
        autosaveTask = nil
        guard isDirty else {
            return
        }
        isSaving = true
        defer {
            isSaving = false
        }
        document.updatedAt = Date()
        do {
            try persistence.save(document)
            isDirty = false
            lastSavedAt = document.updatedAt
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            scheduleAutosave(after: Self.retryDelay)
            throw error
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func stop(flushing: Bool) throws {
        autosaveTask?.cancel()
        autosaveTask = nil
        if flushing {
            try saveNow()
        }
        isStopped = true
    }

    private func markDirty() {
        document.updatedAt = Date()
        isDirty = true
        errorMessage = nil
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        scheduleAutosave(after: Self.autosaveDelay)
    }

    private func scheduleAutosave(after delay: UInt64) {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else {
                return
            }
            do {
                try saveNow()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

@MainActor
final class NoteSessionPool: ObservableObject {
    @Published private(set) var errorMessage: String?

    private let persistence: any NotePersisting
    private var sessions: [UUID: NoteDocumentSession] = [:]

    init(persistence: any NotePersisting = NoteFileStore.live) {
        self.persistence = persistence
    }

    func session(for note: ProjectNote) -> NoteDocumentSession {
        if let session = sessions[note.id] {
            return session
        }
        let session = NoteDocumentSession(noteID: note.id, persistence: persistence)
        sessions[note.id] = session
        return session
    }

    func retainedSession(forNoteID noteID: UUID) -> NoteDocumentSession? {
        sessions[noteID]
    }

    var hasUnsavedChanges: Bool {
        sessions.values.contains(where: \.isDirty)
    }

    func save(noteID: UUID) {
        do {
            try sessions[noteID]?.saveNow()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveAll() throws {
        var firstError: (any Error)?
        for noteID in sessions.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            do {
                try sessions[noteID]?.saveNow()
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            errorMessage = firstError.localizedDescription
            throw firstError
        }
        errorMessage = nil
    }

    func archive(noteIDs: Set<UUID>) {
        for noteID in noteIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            do {
                try sessions[noteID]?.saveNow()
                try persistence.archive(noteID: noteID)
                try sessions[noteID]?.stop(flushing: false)
                sessions.removeValue(forKey: noteID)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        errorMessage = nil
    }

    func reconcile(validNoteIDs: Set<UUID>) {
        let removedIDs = Set(sessions.keys).subtracting(validNoteIDs)
        for noteID in removedIDs {
            do {
                try sessions[noteID]?.stop(flushing: true)
                sessions.removeValue(forKey: noteID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func terminateAll() {
        for session in sessions.values {
            try? session.stop(flushing: false)
        }
        sessions.removeAll()
    }

    func dismissError() {
        errorMessage = nil
    }
}
