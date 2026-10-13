"""Health checks that explain what is wrong in plain language."""

import stat
from pathlib import Path
from typing import Dict, List

from . import PROTOCOL, VERSION, paths, proc, status


def check(name: str, ok: bool, detail: str) -> Dict[str, object]:
    return {"name": name, "ok": ok, "detail": detail}


def toolkit_is_protected() -> bool:
    root = paths.opt_root()
    if not root.exists():
        return False
    for path in [root, *root.rglob("*")]:
        try:
            info = path.lstat()
        except OSError:
            return False
        if info.st_uid != 0 or (info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)):
            if not stat.S_ISLNK(info.st_mode):
                return False
    return True


def run_checks() -> List[Dict[str, object]]:
    tools = status.tools()
    checks = [
        check("Toolkit", True, f"version {VERSION}, protocol {PROTOCOL}"),
        check(
            "Toolkit permissions",
            toolkit_is_protected(),
            "owned by root and not writable by members",
        ),
        check("tmux", tools["tmux"] is not None, tools["tmux"] or "not installed"),
        check("git", tools["git"] is not None, tools["git"] or "not installed"),
        check("Claude Code", tools["claude"] is not None, tools["claude"] or "not installed"),
    ]
    linger = Path("/var/lib/systemd/linger") / proc.caller()
    if Path("/run/systemd/system").is_dir():
        checks.append(
            check(
                "Sessions survive sign-out",
                linger.exists(),
                "linger enabled" if linger.exists() else "run server setup to enable linger",
            )
        )
    tailscale = status.setup.tailscale_status()
    checks.append(
        check(
            "Tailscale",
            tailscale.get("state") == "Running",
            str(tailscale.get("dnsName") or tailscale.get("state") or "not installed"),
        )
    )
    return checks
