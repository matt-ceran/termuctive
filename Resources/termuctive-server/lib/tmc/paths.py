"""Filesystem layout of a Termuctive server.

Environment overrides exist so tests can run the toolkit inside temporary directories.
"""

import os
from pathlib import Path

from . import TOOLKIT_ROOT


def opt_root() -> Path:
    return Path(os.environ.get("TMC_OPT_ROOT", "/opt/termuctive"))


def srv_root() -> Path:
    return Path(os.environ.get("TMC_SRV_ROOT", "/srv/termuctive"))


def stable_tmc() -> Path:
    """The path sudoers rules and hooks refer to; it survives toolkit upgrades."""
    return opt_root() / "bin" / "tmc"


def share(name: str) -> Path:
    return TOOLKIT_ROOT / "share" / name


def run_dir(slug: str) -> Path:
    return srv_root() / "run" / slug


def meta_dir(slug: str) -> Path:
    return srv_root() / "meta" / slug


def project_file(slug: str) -> Path:
    return meta_dir(slug) / "project.json"


def member_dir(slug: str, user: str) -> Path:
    return meta_dir(slug) / "members" / user


def projects_dir() -> Path:
    return srv_root() / "projects"


def shared_dir(slug: str) -> Path:
    return srv_root() / "shared" / slug


def tmux_socket(slug: str, user: str) -> Path:
    return run_dir(slug) / f"{user}.sock"


def project_group(slug: str) -> str:
    return f"tmc-{slug}"


ADMIN_GROUP = "tmc-admins"
