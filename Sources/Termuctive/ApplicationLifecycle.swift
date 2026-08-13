import AppKit

@MainActor
final class TermuctiveApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var workspaceStore: WorkspaceStore?
    weak var editorSessions: EditorSessionPool?
    weak var noteSessions: NoteSessionPool?

    private var isSavingBeforeTermination = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let hasUnsavedContent =
            editorSessions?.hasUnsavedChanges == true
            || noteSessions?.hasUnsavedChanges == true
        let hasPendingWorkspaceSave = workspaceStore?.hasPendingPersistence == true
        guard
            hasUnsavedContent || hasPendingWorkspaceSave
        else {
            return .terminateNow
        }
        guard !isSavingBeforeTermination else {
            return .terminateLater
        }
        guard hasUnsavedContent else {
            flushWorkspaceAndTerminate(sender)
            return .terminateLater
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes before quitting?"
        alert.informativeText =
            "One or more files or notes in Termuctive have unsaved changes."
        alert.addButton(withTitle: "Save All and Quit")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Without Saving")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveAllAndTerminate(sender)
            return .terminateLater
        case .alertThirdButtonReturn:
            if hasPendingWorkspaceSave {
                flushWorkspaceAndTerminate(sender)
                return .terminateLater
            }
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    private func saveAllAndTerminate(_ application: NSApplication) {
        isSavingBeforeTermination = true
        Task { @MainActor [weak self] in
            var firstError: (any Error)?
            do {
                try await self?.editorSessions?.saveAllBuffers()
            } catch {
                firstError = error
            }
            do {
                try self?.noteSessions?.saveAll()
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
            do {
                try await self?.workspaceStore?.flushPersistence()
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }

            if let firstError {
                self?.isSavingBeforeTermination = false
                application.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert(error: firstError)
                alert.messageText = "Termuctive could not save every workspace, file, and note."
                alert.runModal()
            } else {
                application.reply(toApplicationShouldTerminate: true)
            }
        }
    }

    private func flushWorkspaceAndTerminate(_ application: NSApplication) {
        isSavingBeforeTermination = true
        Task { @MainActor [weak self] in
            do {
                try await self?.workspaceStore?.flushPersistence()
                application.reply(toApplicationShouldTerminate: true)
            } catch {
                self?.isSavingBeforeTermination = false
                application.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert(error: error)
                alert.messageText = "Termuctive could not save the workspace."
                alert.runModal()
            }
        }
    }
}
