import Foundation

/// Builds the ssh command that attaches a pane to its persistent session on a server.
enum CloudTerminalLauncher {
    static func launch(
        host: CloudHost,
        binding: CloudProjectBinding,
        pane: TerminalPane,
        paths: SSHPaths,
        initialCommand: String? = nil
    ) -> RemoteTerminalLaunch {
        let remoteCommand = TMCClient.attachCommand(
            slug: binding.slug,
            paneID: pane.id,
            workingDirectory: pane.workingDirectory,
            initialCommand: initialCommand
        )
        return RemoteTerminalLaunch(
            executable: "/usr/bin/ssh",
            arguments: [
                "-F", paths.configURL.path,
                "-tt",
                "-o", "BatchMode=yes",
                // Each pane gets its own connection so a busy pane never delays another.
                "-o", "ControlPath=none",
                host.alias,
                "--",
                ShellQuoting.command(remoteCommand),
            ],
            hostLabel: host.name
        )
    }
}
