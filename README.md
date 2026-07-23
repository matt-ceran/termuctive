# Termuctive

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
