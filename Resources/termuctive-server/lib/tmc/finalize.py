"""Post-transfer fixes that make a project copied from a Mac behave on Linux."""

import os
import subprocess
from pathlib import Path
from typing import Dict, List, Optional

from . import validate

CACHE_DIRECTORIES = {
    "node_modules",
    ".venv",
    "venv",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    ".next",
    ".turbo",
    ".vite",
    ".git",
}

# Repository settings that only make sense on macOS.
MAC_ONLY_GIT_SETTINGS = ("core.fsmonitor", "core.untrackedcache")


def git(arguments: List[str], cwd: Optional[str] = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *arguments],
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def git_value(root: str, key: str) -> List[str]:
    result = git(["-C", root, "config", "--local", "--get-all", key])
    return result.stdout.splitlines() if result.returncode == 0 else []


def fix_repository(root: str) -> List[str]:
    changes = []
    if git_value(root, "core.ignorecase") != ["false"]:
        git(["-C", root, "config", "--local", "core.ignorecase", "false"])
        changes.append("core.ignorecase=false (Linux file names are case-sensitive)")
    for key in MAC_ONLY_GIT_SETTINGS:
        if git_value(root, key):
            git(["-C", root, "config", "--local", "--unset-all", key])
            changes.append(f"removed {key}")
    helpers = git_value(root, "credential.helper")
    if any("osxkeychain" in helper for helper in helpers):
        git(["-C", root, "config", "--local", "--unset-all", "credential.helper"])
        changes.append("removed the macOS keychain credential helper")
    locked = lock_missing_worktrees(root)
    if locked:
        changes.append(f"locked {len(locked)} worktree(s) that were not copied")
    return changes


def lock_missing_worktrees(root: str) -> List[str]:
    """Worktrees left on the Mac stay registered; locking them stops `git worktree prune`
    from deleting their records, so they can be copied later."""
    listing = git(["-C", root, "worktree", "list", "--porcelain"]).stdout
    locked = []
    for block in listing.strip().split("\n\n"):
        lines = block.splitlines()
        if not lines or not lines[0].startswith("worktree "):
            continue
        path = lines[0][len("worktree ") :]
        is_locked = any(line == "locked" or line.startswith("locked ") for line in lines)
        if path == root or is_locked or os.path.exists(path):
            continue
        result = git(["-C", root, "worktree", "lock", "--reason", "Not copied to this server", path])
        if result.returncode == 0:
            locked.append(path)
    return locked


def ensure_safe_directory() -> None:
    existing = git(["config", "--global", "--get-all", "safe.directory"]).stdout.split()
    if "*" not in existing:
        git(["config", "--global", "--add", "safe.directory", "*"])


def environment_files(root: str) -> List[Path]:
    found = []
    for directory, subdirectories, files in os.walk(root):
        subdirectories[:] = [name for name in subdirectories if name not in CACHE_DIRECTORIES]
        for name in files:
            if name == ".env" or (name.startswith(".env.") and not name.endswith(".example")):
                found.append(Path(directory) / name)
    return found


def protect_environment_files(root: str) -> List[str]:
    protected = []
    for path in environment_files(root):
        if path.is_symlink():
            continue
        os.chmod(path, 0o600)
        protected.append(str(path))
    return protected


def finalize(root: str) -> Dict[str, object]:
    root = validate.absolute_path(root)
    if not os.path.isdir(root):
        raise validate.ValidationError(f"{root} does not exist on this server.")
    report: Dict[str, object] = {"root": root, "git": [], "environmentFiles": []}
    if os.path.exists(os.path.join(root, ".git")):
        ensure_safe_directory()
        report["git"] = fix_repository(root)
    report["environmentFiles"] = protect_environment_files(root)
    return report


# Git identity and settings copied from the Mac.

MAC_ONLY_GITCONFIG_KEYS = {
    "core.fsmonitor",
    "core.untrackedcache",
    "core.editor",
    "diff.tool",
    "merge.tool",
}


def sanitize_gitconfig(source: str) -> Dict[str, object]:
    """Writes the Mac's ~/.gitconfig as ~/.gitconfig.mac without Mac-only settings
    and includes it from ~/.gitconfig."""
    home = Path(os.path.expanduser("~"))
    imported = home / ".gitconfig.mac"
    imported.write_text(source)
    os.chmod(imported, 0o600)
    removed = []
    listing = git(["config", "-f", str(imported), "--name-only", "--list"]).stdout.splitlines()
    for key in sorted(set(listing)):
        lowered = key.lower()
        values = git(["config", "-f", str(imported), "--get-all", key]).stdout.splitlines()
        mac_value = any(
            marker in value
            for value in values
            for marker in ("osxkeychain", "/Applications/", "/opt/homebrew/", "/usr/local/bin/")
        )
        if lowered in MAC_ONLY_GITCONFIG_KEYS or lowered.startswith("difftool.") or (
            lowered.startswith("mergetool.")
        ) or mac_value:
            git(["config", "-f", str(imported), "--unset-all", key])
            removed.append(key)
    includes = git(["config", "--global", "--get-all", "include.path"]).stdout.split()
    if "~/.gitconfig.mac" not in includes and str(imported) not in includes:
        git(["config", "--global", "--add", "include.path", "~/.gitconfig.mac"])
    ensure_safe_directory()
    return {"path": str(imported), "removed": removed}


def make_directories(paths: List[str]) -> List[str]:
    """Creates destination folders for an upload inside the caller's own space."""
    home = os.path.expanduser("~")
    created = []
    for raw in paths:
        path = validate.absolute_path(raw)
        if not validate.is_within(path, home):
            raise validate.ValidationError(f"{path} is outside your home folder.")
        os.makedirs(path, exist_ok=True)
        created.append(path)
    return created
