"""Shared Claude memory: one folder every project member's Claude Code reads and writes.

Claude Code keeps automatic memory per project folder. Members work in the same
project path on the server, so linking each member's memory folder to one shared
folder gives every agent the same memories.
"""

import filecmp
import hashlib
import os
import shutil
from pathlib import Path
from typing import Dict, List, Optional

from . import paths, validate

INDEX_NAME = "MEMORY.md"
REVIEW_NAME = "MERGE-REVIEW.md"
INDEX_LINE_LIMIT = 200


def project_key(path: str) -> str:
    """Claude Code's folder name for a project path."""
    return "".join(character if character.isascii() and character.isalnum() else "-" for character in path)


def shared_memory_dir(slug: str) -> Path:
    return paths.meta_dir(slug) / "claude-memory"


def member_memory_link(home: str, root: str) -> Path:
    return Path(home) / ".claude" / "projects" / project_key(root) / "memory"


def link_member(home: str, root: str, shared: Path, uid: int, gid: int) -> None:
    """Points a member's memory folder for `root` at the shared folder.

    Existing memories are merged into the shared folder first, so nothing is lost.
    """
    link = member_memory_link(home, root)
    link.parent.mkdir(parents=True, exist_ok=True)
    for directory in (link.parent.parent.parent, link.parent.parent, link.parent):
        try:
            os.chown(directory, uid, gid)
        except OSError:
            pass
    if link.is_symlink():
        if os.readlink(link) == str(shared):
            return
        link.unlink()
    elif link.is_dir():
        merge(link, shared, member=None)
        shutil.rmtree(link)
    link.symlink_to(shared)
    os.lchown(link, uid, gid)


def merge(source: Path, target: Path, member: Optional[str]) -> Dict[str, List[str]]:
    """Adds `source` memories to `target`.

    New files are copied, identical files are skipped, and a file that differs is kept
    beside the original as `<name>.<member>.md` and listed in MERGE-REVIEW.md. The index
    file is merged line by line.
    """
    target.mkdir(parents=True, exist_ok=True)
    report: Dict[str, List[str]] = {"added": [], "identical": [], "conflicts": [], "warnings": []}
    for path in sorted(source.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        relative = path.relative_to(source)
        destination = target / relative
        if relative.name == INDEX_NAME and relative.parent == Path("."):
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not destination.exists():
            shutil.copy2(path, destination)
            report["added"].append(str(relative))
        elif filecmp.cmp(path, destination, shallow=False):
            report["identical"].append(str(relative))
        else:
            suffix = member or hashlib.sha1(path.read_bytes()).hexdigest()[:8]
            alternative = destination.with_name(f"{destination.stem}.{suffix}{destination.suffix}")
            shutil.copy2(path, alternative)
            report["conflicts"].append(str(relative))

    source_index = source / INDEX_NAME
    if source_index.exists():
        merged_lines = merge_index(target / INDEX_NAME, source_index)
        if merged_lines > INDEX_LINE_LIMIT:
            report["warnings"].append(
                f"{INDEX_NAME} now has {merged_lines} lines; Claude Code only loads the first "
                f"{INDEX_LINE_LIMIT}. Ask an agent to tidy it."
            )
    if report["conflicts"]:
        write_review(target, report["conflicts"], member)
    return report


def merge_index(target_index: Path, source_index: Path) -> int:
    existing = target_index.read_text().splitlines() if target_index.exists() else []
    seen = {line.strip() for line in existing if line.strip()}
    additions = [
        line for line in source_index.read_text().splitlines() if line.strip() and line.strip() not in seen
    ]
    lines = existing + additions
    target_index.write_text("\n".join(lines) + "\n")
    return len(lines)


def write_review(target: Path, conflicts: List[str], member: Optional[str]) -> None:
    review = target / REVIEW_NAME
    header = [] if review.exists() else [
        "# Memory merge review",
        "",
        "These memories existed in two versions when project members' memories were combined.",
        "Each alternative sits beside the original with the member's name in the file name.",
        "Ask an agent to reconcile them, then delete this file.",
        "",
    ]
    entries = [f"- {name} (other version from {member or 'an import'})" for name in conflicts]
    with review.open("a") as handle:
        handle.write("\n".join(header + entries) + "\n")


def merge_into_shared(
    slug: str, source: str, into: Optional[str] = None
) -> Dict[str, List[str]]:
    """Merges memories uploaded by the calling member into the project's shared memory,
    or into a memory folder inside the project (such as a repository's memory/ folder)."""
    from . import admin, proc

    slug = validate.slug(slug)
    source_path = Path(validate.absolute_path(source))
    home = os.path.expanduser("~")
    if not validate.is_within(str(source_path), home):
        raise validate.ValidationError("Memories to merge must be uploaded inside your home folder.")
    project = admin.load_project(slug) or {}
    if proc.caller() not in admin.project_members(project):
        raise validate.ValidationError("You are not a member of this cloud project.")
    target = shared_memory_dir(slug)
    if into:
        into = validate.absolute_path(into)
        if not validate.is_within(into, str(project.get("root", ""))):
            raise validate.ValidationError("Memories can only be merged inside the project.")
        target = Path(into)
    return merge(source_path, target, member=proc.caller())
