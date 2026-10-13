"""Privileged server administration.

Members reach these commands through a sudoers rule that only allows
`/opt/termuctive/bin/tmc admin ...`, so every argument is validated and every
operation re-checks who the human caller is.
"""

import grp
import os
import pwd
import shutil
import subprocess
import time
from pathlib import Path
from typing import Dict, List, Optional

from . import paths, proc, validate
from .jsonio import locked, read_json, write_json_atomic


class AdminError(RuntimeError):
    pass


# Authorization


def caller() -> str:
    return proc.caller()


def is_admin(name: str) -> bool:
    if name == "root":
        return True
    try:
        return name in grp.getgrnam(paths.ADMIN_GROUP).gr_mem
    except KeyError:
        return False


def require_root() -> None:
    if not proc.is_root():
        raise AdminError("This command must run through sudo.")


def require_admin() -> None:
    require_root()
    if not is_admin(caller()):
        raise AdminError("Only the server administrator can do this.")


# Accounts and groups


def user_exists(name: str) -> bool:
    try:
        pwd.getpwnam(name)
        return True
    except KeyError:
        return False


def group_exists(name: str) -> bool:
    try:
        grp.getgrnam(name)
        return True
    except KeyError:
        return False


def ensure_group(name: str) -> None:
    if not group_exists(name):
        proc.run(["groupadd", name])


def add_to_group(user: str, group: str) -> None:
    ensure_group(group)
    if user not in grp.getgrnam(group).gr_mem:
        proc.run(["usermod", "-aG", group, user])


def install_authorized_key(user: str, key: str) -> None:
    entry = pwd.getpwnam(user)
    ssh_directory = Path(entry.pw_dir) / ".ssh"
    ssh_directory.mkdir(mode=0o700, exist_ok=True)
    authorized = ssh_directory / "authorized_keys"
    existing = authorized.read_text().splitlines() if authorized.exists() else []
    key_material = " ".join(key.split()[:2])
    if not any(" ".join(line.split()[:2]) == key_material for line in existing):
        existing.append(key)
    authorized.write_text("\n".join(line for line in existing if line.strip()) + "\n")
    for path in (ssh_directory, authorized):
        os.chown(path, entry.pw_uid, entry.pw_gid)
    os.chmod(ssh_directory, 0o700)
    os.chmod(authorized, 0o600)


def write_sudoers(name: str, rule: str) -> None:
    directory = Path(os.environ.get("TMC_SUDOERS_DIR", "/etc/sudoers.d"))
    target = directory / name
    temporary = directory / f".{name}.tmp"
    temporary.write_text(rule)
    os.chmod(temporary, 0o440)
    if shutil.which("visudo"):
        proc.run(["visudo", "-cf", str(temporary)])
    os.replace(temporary, target)


def member_sudoers_rule(user: str) -> str:
    return f"{user} ALL=(root) NOPASSWD: {paths.stable_tmc()} admin *\n"


def admin_sudoers_rule(user: str) -> str:
    return f"{user} ALL=(ALL) NOPASSWD: ALL\n"


def has_systemd() -> bool:
    return Path("/run/systemd/system").is_dir()


def user_add(name: str, home: str, key: str) -> Dict[str, object]:
    require_admin()
    name = validate.user(name)
    home = validate.home_path(home)
    key = validate.public_key(key)

    created = False
    if user_exists(name):
        current_home = pwd.getpwnam(name).pw_dir
        if current_home != home:
            raise AdminError(f"{name} already exists with home {current_home}, not {home}.")
    else:
        parent = Path(home).parent
        parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        proc.run(
            [
                "useradd",
                "--create-home",
                "--home-dir",
                home,
                "--shell",
                "/bin/bash",
                "--user-group",
                name,
            ]
        )
        created = True

    install_authorized_key(name, key)
    write_sudoers(f"termuctive-member-{name}", member_sudoers_rule(name))
    if has_systemd() and shutil.which("loginctl"):
        proc.run(["loginctl", "enable-linger", name], check=False)
    enable_dispatch(name)
    return {"user": name, "home": home, "created": created}


DISPATCH_UNIT = "/etc/systemd/system/termuctive-dispatch@.service"


def dispatch_unit() -> str:
    return (
        "[Unit]\n"
        "Description=Termuctive task dispatcher for %i\n"
        "After=network-online.target\n\n"
        "[Service]\n"
        "User=%i\n"
        f"ExecStart={paths.stable_tmc()} dispatch --interval 3\n"
        "Restart=always\n"
        "RestartSec=5\n\n"
        "[Install]\n"
        "WantedBy=multi-user.target\n"
    )


def enable_dispatch(user: str) -> None:
    """Delivers teammates' tasks to this member's sessions even when no Mac is connected."""
    if not has_systemd():
        return
    unit = Path(DISPATCH_UNIT)
    if not unit.exists() or unit.read_text() != dispatch_unit():
        unit.write_text(dispatch_unit())
        proc.run(["systemctl", "daemon-reload"], check=False)
    proc.run(["systemctl", "enable", "--now", f"termuctive-dispatch@{user}.service"], check=False)


def grant_admin(name: str) -> None:
    require_root()
    name = validate.user(name)
    add_to_group(name, paths.ADMIN_GROUP)
    write_sudoers(f"termuctive-admin-{name}", admin_sudoers_rule(name))


def install_claude(user: str) -> Dict[str, object]:
    require_root()
    user = validate.user(user)
    if not (is_admin(caller()) or caller() == user):
        raise AdminError("You can only install Claude Code for your own account.")
    home = Path(pwd.getpwnam(user).pw_dir)
    binary = home / ".local" / "bin" / "claude"
    if binary.exists():
        return {"user": user, "installed": False, "path": str(binary)}
    proc.run(
        user_command(user, ["bash", "-lc", "curl -fsSL https://claude.ai/install.sh | bash"]),
        capture=False,
    )
    return {"user": user, "installed": binary.exists(), "path": str(binary)}


def user_command(user: str, command: List[str]) -> List[str]:
    """Runs `command` as `user` with that user's own home and identity.

    `runuser -u` keeps the caller's environment, so HOME would otherwise still point
    at root's home and files would land there.
    """
    entry = pwd.getpwnam(user)
    return [
        "runuser",
        "-u",
        user,
        "--",
        "env",
        f"HOME={entry.pw_dir}",
        f"USER={user}",
        f"LOGNAME={user}",
        f"SHELL={entry.pw_shell or '/bin/bash'}",
        *command,
    ]


# Projects


def load_project(slug: str) -> Optional[Dict[str, object]]:
    return read_json(paths.project_file(slug))


def project_members(project: Dict[str, object]) -> List[str]:
    members = project.get("members")
    return [m for m in members if isinstance(m, str)] if isinstance(members, list) else []


def chown_group(path: Path, owner: str, group: str, mode: int) -> None:
    os.chown(path, pwd.getpwnam(owner).pw_uid, grp.getgrnam(group).gr_gid)
    os.chmod(path, mode)


def project_create(slug: str, root: str, owner: str) -> Dict[str, object]:
    require_root()
    slug = validate.slug(slug)
    root = validate.absolute_path(root)
    owner = validate.user(owner)
    if not (is_admin(caller()) or caller() == owner):
        raise AdminError("You can only create projects that you own.")
    if not user_exists(owner):
        raise AdminError(f"No account named {owner} exists on this server.")
    owner_home = pwd.getpwnam(owner).pw_dir
    allowed_roots = [owner_home, str(paths.projects_dir() / slug)]
    if not any(validate.is_within(root, allowed) for allowed in allowed_roots):
        raise AdminError(f"Project folders must live inside {owner_home}.")

    group = paths.project_group(slug)
    project_file = paths.project_file(slug)
    with locked(project_file):
        existing = load_project(slug)
        if existing and (existing.get("root") != root or existing.get("owner") != owner):
            raise AdminError(f"A different project already uses the name {slug!r}.")

        add_to_group(owner, group)
        meta = paths.meta_dir(slug)
        members = meta / "members"
        for directory in (paths.srv_root() / "meta", paths.srv_root() / "run"):
            directory.mkdir(mode=0o755, parents=True, exist_ok=True)
        meta.mkdir(exist_ok=True)
        chown_group(meta, "root", group, 0o2755)
        members.mkdir(exist_ok=True)
        chown_group(members, "root", group, 0o2755)
        member_directory = members / owner
        member_directory.mkdir(exist_ok=True)
        chown_group(member_directory, owner, group, 0o2755)
        run_directory = paths.run_dir(slug)
        run_directory.mkdir(exist_ok=True)
        chown_group(run_directory, "root", group, 0o2770)

        if not Path(root).exists():
            proc.run(user_command(owner, ["mkdir", "-p", root]))

        paths.projects_dir().mkdir(mode=0o755, parents=True, exist_ok=True)
        link = paths.projects_dir() / slug
        if str(link) != root and not (link.is_symlink() and os.readlink(link) == root):
            if link.is_symlink():
                link.unlink()
            elif link.exists():
                raise AdminError(f"{link} already exists and is not a project link.")
            link.symlink_to(root)

        project = existing or {
            "slug": slug,
            "root": root,
            "owner": owner,
            "members": [owner],
            "created": int(time.time()),
        }
        write_json_atomic(project_file, project, mode=0o644)
        os.chown(project_file, 0, grp.getgrnam(group).gr_gid)
    return project


def project_list(user: Optional[str] = None) -> List[Dict[str, object]]:
    user = user or caller()
    meta_root = paths.srv_root() / "meta"
    projects = []
    if not meta_root.is_dir():
        return projects
    for entry in sorted(meta_root.iterdir()):
        project = read_json(entry / "project.json")
        if not isinstance(project, dict):
            continue
        if is_admin(user) or user in project_members(project):
            projects.append(project)
    return projects


def run_as(user: str, command: List[str]) -> subprocess.CompletedProcess:
    return proc.run(user_command(user, command), check=False)
