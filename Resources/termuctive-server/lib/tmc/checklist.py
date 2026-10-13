"""What still needs a human after moving a project: sign-ins and missing pieces."""

import os
import subprocess
from pathlib import Path
from typing import Dict, List, Optional

from . import proc, status


def item(name: str, ok: bool, detail: str, action: Optional[str] = None) -> Dict[str, object]:
    return {"name": name, "ok": ok, "detail": detail, "action": action}


def git_identity() -> Optional[str]:
    name = proc.output(["git", "config", "--includes", "--global", "user.name"])
    email = proc.output(["git", "config", "--includes", "--global", "user.email"])
    if name and email:
        return f"{name.strip()} <{email.strip()}>"
    return None


def gh_signed_in() -> bool:
    if not proc.have("gh"):
        return False
    return (
        subprocess.run(
            ["gh", "auth", "status"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode
        == 0
    )


def aws_profiles() -> List[str]:
    config = Path(os.path.expanduser("~/.aws/config"))
    profiles = []
    try:
        for line in config.read_text().splitlines():
            line = line.strip()
            if line.startswith("[") and line.endswith("]"):
                profiles.append(line[1:-1].replace("profile ", "", 1))
    except OSError:
        pass
    return profiles


def collect(root: Optional[str] = None) -> List[Dict[str, object]]:
    claude = status.claude_path()
    credentials = Path(os.path.expanduser("~/.claude/.credentials.json")).exists()
    items = [
        item(
            "Claude Code",
            claude is not None and credentials,
            "signed in" if credentials else ("installed, not signed in" if claude else "missing"),
            None if credentials else "claude",
        ),
        item(
            "GitHub",
            gh_signed_in(),
            "signed in" if gh_signed_in() else "not signed in",
            None if gh_signed_in() else "gh auth login && gh auth setup-git",
        ),
    ]
    identity = git_identity()
    items.append(
        item(
            "Git identity",
            identity is not None,
            identity or "not set",
            None if identity else 'git config --global user.name "Your Name"',
        )
    )
    profiles = aws_profiles()
    if profiles:
        items.append(item("AWS profiles", True, ", ".join(profiles)))
    if root:
        missing = []
        if (Path(root) / "package.json").exists() and not (Path(root) / "node_modules").exists():
            missing.append("node_modules")
        python_markers = ("requirements.txt", "requirements.lock", "pyproject.toml")
        if any((Path(root) / name).exists() for name in python_markers) and not (
            Path(root) / ".venv"
        ).exists():
            missing.append(".venv")
        items.append(
            item(
                "Project dependencies",
                not missing,
                "installed" if not missing else "missing " + ", ".join(missing),
                None if not missing else f"tmc hydrate --root {root}",
            )
        )
    return items


def render(items: List[Dict[str, object]]) -> str:
    lines = ["", "Termuctive cloud checklist", ""]
    for entry in items:
        mark = "✓" if entry["ok"] else "•"
        lines.append(f"  {mark} {entry['name']}: {entry['detail']}")
        if entry.get("action"):
            lines.append(f"      run: {entry['action']}")
    lines.append("")
    return "\n".join(lines)
