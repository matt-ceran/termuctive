# Cloud projects

Cloud projects run a project's terminals on an always-on Linux server instead of this Mac.
Sessions keep running when Termuctive quits or the Mac sleeps, collaborators can work in
the same project from their own Macs, and their Claude Code agents can hand each other work.

Everything runs on a server you control, reached over SSH through Termuctive's own keys
and settings in `~/.termuctive/ssh/`. Each person's Claude Code signs in with their own
subscription.

## What you need

- A machine that stays on with Ubuntu 24.04 Server installed (a spare PC works well).
- [Tailscale](https://tailscale.com) on the server and on every Mac that connects, so the
  server is reachable from anywhere without opening router ports. The free plan covers up
  to six people.
- Termuctive on each collaborator's Mac.

## Prepare the server (once)

1. Install Ubuntu 24.04 Server. Enable OpenSSH during installation and create an
   administrator account, for example `serveradmin` (Ubuntu reserves `admin`). Leave
   "Set up this disk as an LVM group" unchecked so the system gets the whole disk.
2. In the computer's firmware settings, set it to power on after a power loss.
3. Note its address on your network, for example `192.168.1.50`. If this Mac can't
   reach that address, as on many apartment and campus networks, install Tailscale on
   the server first (`curl -fsSL https://tailscale.com/install.sh | sh`, then
   `sudo tailscale up --qr`) and use its Tailscale name as the address.

## Set up the server from Termuctive

Choose **Cloud > Set Up Server...** and enter the address and administrator account.

- Type the administrator password once. Termuctive installs its own key, so later
  connections need no password.
- Setup runs in a visible terminal: type the administrator password when `sudo` asks.
  It installs the tools projects need, creates your account with the same home folder
  as on this Mac (so every path in your projects, rules and memories still works), keeps
  the server awake, installs GPU drivers when it finds an NVIDIA card, and connects the
  server to Tailscale. Open the Tailscale sign-in link it prints.
- When setup finishes, Termuctive switches to the server's Tailscale name. If this Mac
  is not on Tailscale yet, it keeps using the local address until it is.

**Cloud > *server* Status...** shows memory, disk and GPU use, updates the server toolkit
after Termuctive updates, and ends sessions no pane uses anymore.

## Move a project

Right-click a project and choose **Move Project to Cloud...**.

1. Termuctive scans the project without changing anything. The list covers:
   - the project folder, its git history, `.env` files and local-only folders,
   - every git worktree, with when it was last used,
   - large ignored folders such as archives,
   - folders the project's rules and memories refer to, such as `~/model-data`,
   - Claude conversations and memory for the project,
   - your Claude settings, skills and plugins, `~/.aws` and `~/.gitconfig`.
   Dependency folders such as `node_modules` and `.venv` are rebuilt on the server instead
   of copied. Use **Only Worktrees Used This Week** to skip old worktrees.
2. **Start Copying** copies everything while you keep working. Closing the window keeps
   the copy going, and Termuctive asks before quitting during a copy. Running the move
   again later only sends what changed.
3. **Switch to Cloud** stops the project's terminals on this Mac, copies the last changes,
   and opens *project* (Cloud) beside the original. The original stays untouched.

The cloud copy opens a **Cloud Setup** tab that installs dependencies for the project and
recently used worktrees, then lists what still needs signing in:

- Claude Code: run `claude` once and follow the sign-in link.
- GitHub: run `gh auth login && gh auth setup-git`.

Your Claude history moved too, so `claude --continue` picks up your last conversation.

### What changes in a cloud project

- Panes show the server name in their header. Quitting Termuctive only disconnects;
  closing a pane ends its session on the server.
- After sleep or a network change, panes reconnect on their own. If the server restarts,
  each pane comes back in its last folder and resumes its Claude conversation.
- Dev servers started in cloud panes appear on the same port on this Mac, for example
  `http://localhost:5173`. The Cloud menu lists them.
- Paste an image or drop a file into a cloud terminal to upload it and type its path,
  which Claude Code can then read.
- The IDE pane edits files on the server. Saving never overwrites a newer version saved
  by someone else; you choose which version to keep.
- `/makepdf` and `/movepdf` work, downloading the PDF to this Mac to show it.
- The sidebar shows agent activity for cloud panes, and Termuctive notifies you when a
  cloud agent waits for permission.

## Work with a collaborator

### Invite (project owner)

Right-click the cloud project and choose **Invite Collaborator...**. Enter their account
name and their Mac's home folder (usually `/Users/<name>`), then send them the invite code.
Also invite them to your Tailscale network from the Tailscale admin console.

The invite shares the project, its `.env` files and related folders with them, and links
both of your Claude memories for the project to one shared folder. The code works once and
expires after two days.

Only invite someone you would trust with your laptop: in a shared project each person's
agents can run code and use the project's keys.

### Join (collaborator)

Install Tailscale and accept the invitation, then choose **Cloud > Join Cloud Project...**
and paste the code. Termuctive adds the project to your sidebar and installs Claude Code
for your account on the server. Run `claude` in the project to sign in with your own
subscription.

Choose **Bring My Local Work...** to add your own copy of the project:

- your branches (renamed to `<you>/<branch>` when they would overwrite someone else's),
- each of your checkouts, including uncommitted work and `.env` files, as worktrees named
  after you,
- your Claude conversations, with your memories merged into the shared ones. When the same
  memory differs, both versions are kept and listed in `MERGE-REVIEW.md`.

### Team, watching and handing off work

**Team...** shows each person's sessions and what their agents are doing.

- **Watch** opens a teammate's session read-only in its own window.
- Agents hand work over with the `termuctive` tools Claude Code gets on the server:
  `team_status`, `post_task`, `list_tasks`, `update_task` and `send_message`. A task runs
  automatically in one of the teammate's idle Claude sessions, or the next one to finish,
  even when nobody's Mac is connected, and its result comes back to the session that
  asked.
- Turn off **Run teammates' tasks automatically** in the Team window to review tasks
  before they run. You can also send a task by hand from there.

## Troubleshooting

- **A pane keeps saying Reconnecting:** check that the server is on and reachable
  (`tailscale status` on this Mac), then choose **Cloud > Reconnect Cloud Terminals**.
- **The server needs a Termuctive update:** open the server's Status window and choose
  **Update Server**.
- **Checking the server:** in any cloud pane, `tmc doctor` and `tmc checklist` report
  what is missing.
- **Server administration:** sign in with the administrator account you created during
  installation. Your own account can only run Termuctive's administrative commands.

## Testing

`Scripts/cloud-test-server.sh up` starts a disposable Ubuntu server in Docker on
`127.0.0.1:2222`. With it running, set `TERMUCTIVE_CLOUD_E2E=1` to run the end-to-end
tests in `CloudE2ETests`. With `xcodebuild`, pass it as `TEST_RUNNER_TERMUCTIVE_CLOUD_E2E=1`,
and add `TEST_RUNNER_PATH="$PATH"` when `docker` is outside the system paths. The server
toolkit's own tests run with `python3 -m unittest discover -s Tests/ServerToolkit`.
