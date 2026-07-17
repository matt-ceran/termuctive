# Termuctive

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
