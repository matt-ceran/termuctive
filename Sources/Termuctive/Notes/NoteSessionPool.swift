import Foundation

@MainActor
final class NoteDocumentSession: ObservableObject, Identifiable {
    let id: UUID

    @Published private(set) var document: NoteDocument
    @Published private(set) var isDirty = false
    @Published private(set) var isSaving = false
    @Published private(set) var lastSavedAt: Date?
    @Published private(set) var errorMessage: String?

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
        guard document.richTextRTF != data else {
            return
        }
        document.richTextRTF = data
        markDirty()
    }

    func updateDrawing(_ drawing: NoteDrawing) {
        guard document.drawing != drawing else {
            return
        }
        document.drawing = drawing
        markDirty()
    }

    func updateWorkspaceMode(_ mode: NoteWorkspaceMode) {
        guard document.workspaceMode != mode else {
            return
        }
        document.workspaceMode = mode
        markDirty()
    }

    func saveNow() throws {
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
    }

    private func markDirty() {
        document.updatedAt = Date()
        isDirty = true
        errorMessage = nil
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
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

    func save(noteID: UUID) {
        do {
            try sessions[noteID]?.saveNow()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveAll() {
        for noteID in sessions.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            do {
                try sessions[noteID]?.saveNow()
            } catch {
                errorMessage = error.localizedDescription
                return
            }
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
        saveAll()
        for session in sessions.values {
            try? session.stop(flushing: false)
        }
        sessions.removeAll()
    }

    func dismissError() {
        errorMessage = nil
    }
}
