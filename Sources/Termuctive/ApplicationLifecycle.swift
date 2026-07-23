import AppKit

@MainActor
final class TermuctiveApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var editorSessions: EditorSessionPool?

    private var isSavingBeforeTermination = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard editorSessions?.hasUnsavedChanges == true else {
            return .terminateNow
        }
        guard !isSavingBeforeTermination else {
            return .terminateLater
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes before quitting?"
        alert.informativeText =
            "One or more files in Termuctive IDE panes have unsaved changes."
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
        guard let editorSessions else {
            application.reply(toApplicationShouldTerminate: true)
            return
        }
        isSavingBeforeTermination = true
        Task { @MainActor [weak self] in
            do {
                try await editorSessions.saveAllBuffers()
                application.reply(toApplicationShouldTerminate: true)
            } catch {
                self?.isSavingBeforeTermination = false
                application.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert(error: error)
                alert.messageText = "Termuctive could not save every file."
                alert.runModal()
            }
        }
    }
}
