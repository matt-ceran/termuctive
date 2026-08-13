import AppKit

@MainActor
final class TermuctiveApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var editorSessions: EditorSessionPool?
    weak var noteSessions: NoteSessionPool?

    private var isSavingBeforeTermination = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard
            editorSessions?.hasUnsavedChanges == true
                || noteSessions?.hasUnsavedChanges == true
        else {
            return .terminateNow
        }
        guard !isSavingBeforeTermination else {
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

            if let firstError {
                self?.isSavingBeforeTermination = false
                application.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert(error: firstError)
                alert.messageText = "Termuctive could not save every file and note."
                alert.runModal()
            } else {
                application.reply(toApplicationShouldTerminate: true)
            }
        }
    }
}
