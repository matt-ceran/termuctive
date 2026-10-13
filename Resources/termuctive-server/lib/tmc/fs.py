"""File access for Termuctive's editor and PDF panes on cloud projects.

Termuctive decodes and encodes text itself, so these commands move raw bytes, and
writes only succeed when the file still matches what the editor last saw.
"""

import base64
import hashlib
import os
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional

from . import validate

MAXIMUM_TEXT_SIZE = 5 * 1024 * 1024
TREE_LIMIT = 50_000
# Matches the editor's local file navigator (EditorFileTreeBuilder).
IGNORED_NAMES = {
    ".build", ".git", ".gradle", ".next", ".swiftpm", ".terraform", ".tox", ".venv",
    "DerivedData", "__pycache__", "build", "coverage", "dist", "node_modules", "Pods",
    "target", "vendor",
}
IGNORED_FILES = {".DS_Store"}
ABSENT = "absent"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def tree(root: str, limit: int = TREE_LIMIT) -> Dict[str, object]:
    root = validate.absolute_path(root)
    entries: List[List[object]] = []
    truncated = False
    for directory, subdirectories, files in os.walk(root):
        subdirectories[:] = sorted(
            name
            for name in subdirectories
            if name not in IGNORED_NAMES and not os.path.islink(os.path.join(directory, name))
        )
        relative = os.path.relpath(directory, root)
        prefix = "" if relative == "." else relative + "/"
        for name in subdirectories:
            entries.append([prefix + name, True])
        for name in sorted(files):
            if name in IGNORED_FILES:
                continue
            entries.append([prefix + name, False])
        if len(entries) >= limit:
            truncated = True
            break
    return {"entries": entries[:limit], "truncated": truncated}


def read(path: str) -> Dict[str, object]:
    path = validate.absolute_path(path)
    if not os.path.lexists(path):
        return {"exists": False}
    if os.path.isdir(path):
        return {"exists": True, "isDirectory": True}
    size = os.path.getsize(path)
    if size > MAXIMUM_TEXT_SIZE:
        return {"exists": True, "isDirectory": False, "size": size}
    data = Path(path).read_bytes()
    return {
        "exists": True,
        "isDirectory": False,
        "size": size,
        "digest": digest(data),
        "content": base64.b64encode(data).decode(),
    }


def write(path: str, expected: str, data: bytes) -> Dict[str, object]:
    """Replaces the file atomically if it still has the `expected` digest."""
    path = validate.absolute_path(path)
    current = read(path)
    current_digest = current.get("digest") if current.get("exists") else ABSENT
    if current.get("isDirectory") or current_digest != expected:
        return {"conflict": True, "current": current}
    directory = os.path.dirname(path)
    mode = os.stat(path).st_mode & 0o7777 if current.get("exists") else None
    descriptor, temporary = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=directory)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        if mode is not None:
            os.chmod(temporary, mode)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
    return {"written": True, "digest": digest(data)}


def digests(paths: List[str]) -> Dict[str, Optional[str]]:
    result: Dict[str, Optional[str]] = {}
    for raw in paths:
        try:
            path = validate.absolute_path(raw)
        except validate.ValidationError:
            continue
        try:
            if os.path.getsize(path) > MAXIMUM_TEXT_SIZE:
                result[path] = "large-" + str(os.path.getmtime(path))
                continue
            result[path] = digest(Path(path).read_bytes())
        except (OSError, IsADirectoryError):
            result[path] = None
    return result


def recent_pdf(root: str, since: float) -> Dict[str, Optional[str]]:
    """The newest PDF under `root` modified after `since`, for PDF panes."""
    root = validate.absolute_path(root)
    newest: Optional[str] = None
    newest_time = since
    deadline = time.time() + 10
    for directory, subdirectories, files in os.walk(root):
        subdirectories[:] = [name for name in subdirectories if name not in IGNORED_NAMES]
        for name in files:
            if not name.lower().endswith(".pdf"):
                continue
            path = os.path.join(directory, name)
            try:
                modified = os.path.getmtime(path)
            except OSError:
                continue
            if modified > newest_time:
                newest, newest_time = path, modified
        if time.time() > deadline:
            break
    return {"path": newest}


def read_stdin_bytes() -> bytes:
    return sys.stdin.buffer.read()
