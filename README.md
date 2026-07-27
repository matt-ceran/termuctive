# Termuctive

Termuctive is a native macOS workspace for organizing persistent terminal, editor, and PDF panes by project.

## Requirements

Termuctive supports macOS 14 Sonoma or newer.
Published builds are universal and support both Apple silicon and Intel Macs.
Command-line tools such as Codex, OpenCode, and other shells are not bundled, so install those separately if you want to run them inside Termuctive.

## Install a published release

Open [GitHub Releases](https://github.com/matt-ceran/termuctive/releases) and download the newest `Termuctive-<version>-universal.dmg` file.
Only a release with that DMG is a ready-to-run application.
The automatically generated source archives contain source code, not `Termuctive.app`.

Open the DMG, drag `Termuctive.app` to Applications, and launch it from Applications.
A published DMG is signed with Developer ID and notarized by Apple, so it should pass Gatekeeper without a security bypass.
Xcode is not required when installing a published DMG.

## Build and install from source

Install the full current version of Xcode, then run:

```sh
git clone https://github.com/matt-ceran/termuctive.git
cd termuctive
./Scripts/install-local.sh
open "$HOME/Applications/Termuctive.app"
```

The source installer builds for the current Mac architecture, applies a local ad hoc signature, and installs into `~/Applications`.
It does not require an Apple Developer account.
Quit Termuctive before running the installer again.

Each installation stores its workspace data locally at `~/Library/Application Support/Termuctive/workspace.json`.
Cloning the repository does not copy another person's projects, terminal history, credentials, or command-line tool accounts.

## IDE panes

Focus any pane and use its code button, the workspace toolbar, or Pane > Open IDE in Focused Pane to replace that pane with a project editor.
The original terminal process remains alive behind the editor.
The editor includes a searchable file navigator, tabs, syntax coloring, line numbers, conflict-safe saving, and a compact layout for narrow split panes.
Files changed by a terminal, an LLM CLI, or another editor reload automatically when the Termuctive buffer is clean.
If the same file changes on disk while it has unsaved Termuctive edits, the editor asks which version to keep instead of overwriting either version silently.
Use Command-S to save and the terminal button to return to the existing live terminal.

## PDF panes

Termuctive can open the newest PDF created during the current terminal session without stopping the terminal process behind that pane.
Ask Codex to create or identify the PDF first, then type one of these Termuctive commands directly in the same terminal pane and press Return.
Termuctive intercepts these commands before Codex sees them.
It prefers the latest PDF path shown in that terminal session, then falls back to the newest PDF created in the project since the session began.

- `/movepdf` opens the PDF opposite the command terminal.
- `/movepdfleft` opens the PDF in the leftmost pane.
- `/movepdfright` opens the PDF in the rightmost pane.

The same actions are available from the Pane menu.
Use the return arrow in a PDF pane to restore its live terminal.
