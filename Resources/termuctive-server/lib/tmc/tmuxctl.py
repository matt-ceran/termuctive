"""Persistent terminal sessions: one tmux server per (project, member)."""

import os
import shutil
import subprocess
import sys
from typing import Dict, List, Optional

from . import PROTOCOL, paths, validate
from .jsonio import read_json

# Exit codes understood by Termuctive's reconnect policy.
EXIT_SHELL_ENDED = 0
EXIT_FAILED = 1
EXIT_DETACHED = 3
EXIT_INCOMPATIBLE = 4

SESSION_PREFIX = "tmc-"


def session_name(pane: str) -> str:
    return SESSION_PREFIX + pane


def pane_from_session(name: str) -> Optional[str]:
    if not name.startswith(SESSION_PREFIX):
        return None
    try:
        return validate.pane_id(name[len(SESSION_PREFIX) :])
    except validate.ValidationError:
        return None


def tmux_command(slug: str, user: str, *arguments: str) -> List[str]:
    return [
        "tmux",
        "-S",
        str(paths.tmux_socket(slug, user)),
        "-f",
        str(paths.share("tmux.conf")),
        *arguments,
    ]


def has_session(slug: str, user: str, pane: str) -> bool:
    if not paths.tmux_socket(slug, user).exists():
        return False
    result = subprocess.run(
        tmux_command(slug, user, "has-session", "-t", "=" + session_name(pane)),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def project_root(slug: str) -> Optional[str]:
    project = read_json(paths.project_file(slug), {}) or {}
    root = project.get("root")
    return root if isinstance(root, str) else None


def starting_directory(slug: str, requested: Optional[str]) -> str:
    candidates = [requested, project_root(slug), os.path.expanduser("~")]
    for candidate in candidates:
        if candidate and os.path.isdir(candidate):
            return candidate
    return "/"


def session_environment(slug: str, pane: str) -> Dict[str, str]:
    environment = dict(os.environ)
    environment.setdefault("LANG", "C.UTF-8")
    environment["COLORTERM"] = "truecolor"
    environment["TMC_PANE_ID"] = pane
    environment["TMC_PROJECT"] = slug
    return environment


def attach(slug: str, pane: str, cwd: Optional[str], protocol: Optional[int], user: str) -> int:
    if protocol is not None and protocol != PROTOCOL:
        print(
            f"This server runs Termuctive toolkit protocol {PROTOCOL}, "
            f"but the app expects {protocol}. Update the server from Termuctive.",
            file=sys.stderr,
        )
        return EXIT_INCOMPATIBLE
    if not shutil.which("tmux"):
        print("tmux is not installed on this server. Run server setup again.", file=sys.stderr)
        return EXIT_FAILED

    socket_directory = paths.run_dir(slug)
    if not socket_directory.is_dir() or not os.access(socket_directory, os.W_OK | os.X_OK):
        print(
            f"You are not a member of the cloud project {slug!r} on this server.",
            file=sys.stderr,
        )
        return EXIT_FAILED

    environment = session_environment(slug, pane)
    name = session_name(pane)
    if has_session(slug, user, pane):
        command = tmux_command(slug, user, "attach-session", "-t", "=" + name)
    else:
        directory = starting_directory(slug, cwd)
        command = tmux_command(
            slug,
            user,
            "new-session",
            "-A",
            "-s",
            name,
            "-c",
            directory,
            "-e",
            f"TMC_PANE_ID={pane}",
            "-e",
            f"TMC_PROJECT={slug}",
        )
    subprocess.call(command, env=environment)
    return EXIT_DETACHED if has_session(slug, user, pane) else EXIT_SHELL_ENDED


def kill(slug: str, pane: str, user: str) -> int:
    if has_session(slug, user, pane):
        subprocess.run(
            tmux_command(slug, user, "kill-session", "-t", "=" + session_name(pane)),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    return 0


LIST_FORMAT = "\t".join(
    [
        "#{session_name}",
        "#{session_created}",
        "#{session_activity}",
        "#{session_attached}",
        "#{pane_pid}",
        "#{pane_current_command}",
        "#{pane_current_path}",
    ]
)


def list_sessions(slug: str, user: str) -> List[Dict[str, object]]:
    if not paths.tmux_socket(slug, user).exists():
        return []
    result = subprocess.run(
        tmux_command(slug, user, "list-panes", "-a", "-F", LIST_FORMAT),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        return []
    sessions = []
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) != 7:
            continue
        pane = pane_from_session(fields[0])
        if pane is None:
            continue
        sessions.append(
            {
                "pane": pane,
                "created": _int(fields[1]),
                "activity": _int(fields[2]),
                "attached": _int(fields[3]) > 0,
                "pid": _int(fields[4]),
                "command": fields[5],
                "cwd": fields[6],
            }
        )
    return sessions


def _int(value: str) -> int:
    try:
        return int(value)
    except ValueError:
        return 0
