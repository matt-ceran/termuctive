import AppKit

@MainActor
final class TermuctiveApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var workspaceStore: WorkspaceStore?
    weak var editorSessions: EditorSessionPool?
    weak var noteSessions: NoteSessionPool?
    weak var cloud: CloudSessionCoordinator? {
        didSet {
            openPendingInvite()
        }
    }

    private var isSavingBeforeTermination = false
    /// An invite file opened before the workspace finished loading.
    private var pendingInviteURL: URL?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let invite = urls.last(where: { $0.pathExtension == InviteCode.fileExtension })
        else {
            return
        }
        pendingInviteURL = invite
        openPendingInvite()
    }

    private func openPendingInvite() {
        guard let cloud, let url = pendingInviteURL else {
            return
        }
        pendingInviteURL = nil
        cloud.openInvite(at: url)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !isSavingBeforeTermination, cloud?.activeMove?.isWorking == true {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "A project is still moving to the cloud."
            alert.informativeText =
                "Quitting stops the copy. Choose Move Project to Cloud again later to "
                + "continue where it left off."
            alert.addButton(withTitle: "Keep Copying")
            alert.addButton(withTitle: "Quit")
            guard alert.runModal() == .alertSecondButtonReturn else {
                return .terminateCancel
            }
            cloud?.activeMove?.cancel()
        }
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
