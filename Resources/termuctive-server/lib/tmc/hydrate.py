"""Installs a checkout's dependencies on the server.

Dependency folders are never copied from the Mac (they hold macOS binaries), so
each checkout that should be ready to run gets a fresh install here.
"""

import os
import subprocess
from pathlib import Path
from typing import List, Optional, Tuple

from . import proc, validate

NODE_LOCKFILES = (
    ("pnpm-lock.yaml", ["pnpm", "install", "--frozen-lockfile"]),
    ("yarn.lock", ["yarn", "install", "--frozen-lockfile"]),
    ("package-lock.json", ["npm", "ci"]),
)
SKIPPED_DIRECTORIES = {"node_modules", ".venv", "venv", ".git", "dist", "build", ".worktrees"}


def node_projects(root: Path, depth: int = 2) -> List[Tuple[Path, List[str]]]:
    projects = []
    for directory, subdirectories, files in os.walk(root):
        relative_depth = len(Path(directory).relative_to(root).parts)
        subdirectories[:] = [
            name
            for name in subdirectories
            if name not in SKIPPED_DIRECTORIES and not name.startswith(".")
        ]
        if relative_depth >= depth:
            subdirectories[:] = []
        if "package.json" not in files:
            continue
        for lockfile, command in NODE_LOCKFILES:
            if lockfile in files:
                projects.append((Path(directory), command))
                break
        else:
            projects.append((Path(directory), ["npm", "install"]))
    return projects


def python_requirements(root: Path) -> Optional[Path]:
    for name in ("requirements.lock", "requirements.txt"):
        if (root / name).exists():
            return root / name
    return None


def run_step(description: str, command: List[str], cwd: Path) -> bool:
    proc.step(f"{description} ({cwd})")
    if not proc.have(command[0]) and not os.path.isabs(command[0]):
        proc.warn(f"{command[0]} is not installed; skipped.")
        return False
    result = subprocess.run(command, cwd=str(cwd))
    if result.returncode != 0:
        proc.warn(f"{' '.join(command)} failed with exit code {result.returncode}.")
        return False
    return True


def hydrate(root: str) -> int:
    root_path = Path(validate.absolute_path(root))
    if not root_path.is_dir():
        proc.warn(f"{root_path} does not exist.")
        return 1
    failures = 0

    if (root_path / "uv.lock").exists():
        failures += not run_step("Installing Python packages with uv", ["uv", "sync"], root_path)
    else:
        requirements = python_requirements(root_path)
        if requirements is not None:
            venv = root_path / ".venv"
            if proc.have("uv"):
                if not venv.exists():
                    failures += not run_step(
                        "Creating a Python environment", ["uv", "venv", str(venv)], root_path
                    )
                failures += not run_step(
                    f"Installing Python packages from {requirements.name}",
                    ["uv", "pip", "install", "--python", str(venv / "bin" / "python"),
                     "-r", str(requirements)],
                    root_path,
                )
            else:
                if not venv.exists():
                    failures += not run_step(
                        "Creating a Python environment",
                        ["python3", "-m", "venv", str(venv)],
                        root_path,
                    )
                failures += not run_step(
                    f"Installing Python packages from {requirements.name}",
                    [str(venv / "bin" / "pip"), "install", "-r", str(requirements)],
                    root_path,
                )

    for directory, command in node_projects(root_path):
        failures += not run_step("Installing Node packages", command, directory)

    if failures:
        proc.warn(f"{failures} step(s) need attention.")
    else:
        proc.step("Dependencies are ready.")
    return 1 if failures else 0
