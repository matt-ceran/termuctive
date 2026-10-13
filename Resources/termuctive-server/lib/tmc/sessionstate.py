"""Per-pane state kept on the server: where a pane was, and what its agent is doing.

Each member owns their own state folder, so other members can read it but never
change it. The files let Termuctive show live agent activity, and let a pane come
back in the right folder (and resume its Claude conversation) after a reboot.
"""

import os
import time
from pathlib import Path
from typing import Dict, List, Optional

from . import paths, validate
from .jsonio import read_json, write_json_atomic


def state_directory(slug: str, user: str) -> Path:
    return paths.member_dir(slug, user) / "sessions"


def state_file(slug: str, user: str, pane: str) -> Path:
    return state_directory(slug, user) / f"{pane}.json"


def load(slug: str, user: str, pane: str) -> Optional[Dict[str, object]]:
    value = read_json(state_file(slug, user, pane))
    return value if isinstance(value, dict) else None


def update(slug: str, user: str, pane: str, changes: Dict[str, object]) -> Dict[str, object]:
    directory = state_directory(slug, user)
    try:
        directory.mkdir(parents=True, exist_ok=True)
    except OSError:
        return {}
    state = load(slug, user, pane) or {"pane": pane}
    state.update(changes)
    state["updated"] = time.time()
    try:
        write_json_atomic(state_file(slug, user, pane), state, mode=0o644)
    except OSError:
        pass
    return state


def remove(slug: str, user: str, pane: str) -> None:
    try:
        state_file(slug, user, pane).unlink()
    except OSError:
        pass


def all_states(slug: str, user: str) -> Dict[str, Dict[str, object]]:
    states: Dict[str, Dict[str, object]] = {}
    directory = state_directory(slug, user)
    if not directory.is_dir():
        return states
    for entry in directory.glob("*.json"):
        value = read_json(entry)
        if isinstance(value, dict):
            try:
                states[validate.pane_id(entry.stem)] = value
            except validate.ValidationError:
                continue
    return states


def resume_command(state: Optional[Dict[str, object]]) -> Optional[str]:
    """The command that restores a pane whose server session vanished, such as after a reboot."""
    if not state:
        return None
    claude = state.get("claude")
    if not isinstance(claude, dict) or claude.get("ended"):
        return None
    session_id = claude.get("sessionId")
    if not isinstance(session_id, str) or not session_id.replace("-", "").isalnum():
        return None
    return f"claude --resume {session_id}"


def resume_directory(state: Optional[Dict[str, object]]) -> Optional[str]:
    if not state:
        return None
    cwd = state.get("cwd")
    return cwd if isinstance(cwd, str) and os.path.isdir(cwd) else None


# Process trees, so Termuctive can recognize agents other than Claude Code.


def children_map() -> Dict[int, List[int]]:
    children: Dict[int, List[int]] = {}
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            fields = (entry / "stat").read_text().rsplit(")", 1)[1].split()
            parent = int(fields[1])
        except (OSError, IndexError, ValueError):
            continue
        children.setdefault(parent, []).append(int(entry.name))
    return children


def process_tree(root_pid: int, children: Dict[int, List[int]]) -> List[Dict[str, object]]:
    processes = []
    pending = list(children.get(root_pid, []))
    while pending and len(processes) < 64:
        pid = pending.pop()
        pending.extend(children.get(pid, []))
        base = Path("/proc") / str(pid)
        try:
            name = (base / "comm").read_text().strip()
            arguments = (base / "cmdline").read_bytes().split(b"\0")
            executable = os.readlink(base / "exe") if os.access(base / "exe", os.R_OK) else ""
        except OSError:
            continue
        processes.append(
            {
                "pid": pid,
                "name": name,
                "executable": executable,
                "arguments": [part.decode(errors="replace") for part in arguments[:4] if part],
            }
        )
    return processes
