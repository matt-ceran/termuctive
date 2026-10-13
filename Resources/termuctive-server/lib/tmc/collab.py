"""Inviting collaborators to a cloud project, and what they can see of each other."""

import datetime
import grp
import os
import pwd
import secrets
import subprocess
import time
from pathlib import Path
from typing import Dict, List, Optional

from . import admin, memory, paths, proc, sessionstate, validate
from .jsonio import locked, read_json, write_json_atomic

INVITE_LIFETIME_HOURS = 48
INVITE_MARKER = "tmc-invite-"


def invites_dir(slug: str) -> Path:
    return paths.meta_dir(slug) / "invites"


def host_keys() -> List[str]:
    keys = []
    for path in sorted(Path("/etc/ssh").glob("ssh_host_*_key.pub")):
        parts = path.read_text().split()
        if len(parts) >= 2:
            keys.append(f"{parts[0]} {parts[1]}")
    return keys


def run(command: List[str]) -> subprocess.CompletedProcess:
    return subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def grant_tree(path: str, group: str) -> None:
    """Lets the project group read and write a folder tree, including files made later."""
    run(["setfacl", "-R", "-m", f"g:{group}:rwX", path])
    run(["find", path, "-type", "d", "-exec", "setfacl", "-d", "-m", f"g:{group}:rwX", "{}", "+"])


def grant_traverse(path: str, group: str, stop: str) -> None:
    """Lets the group pass through the folders above `path` without listing them."""
    current = Path(path).parent
    while validate.is_within(str(current), stop) and str(current) != "/":
        run(["setfacl", "-m", f"g:{group}:x", str(current)])
        if str(current) == stop:
            break
        current = current.parent


def share_project(slug: str, project: Dict[str, object], extra_paths: List[str]) -> None:
    group = paths.project_group(slug)
    owner = str(project["owner"])
    owner_home = pwd.getpwnam(owner).pw_dir
    root = str(project["root"])
    for path in [root, *extra_paths]:
        if not os.path.exists(path) or not validate.is_within(path, owner_home):
            continue
        grant_traverse(path, group, owner_home)
        grant_tree(path, group)
    if os.path.isdir(os.path.join(root, ".git")):
        run(["git", "-C", root, "config", "core.sharedRepository", "group"])


def share_memory(slug: str, project: Dict[str, object], members: List[str]) -> Path:
    group = paths.project_group(slug)
    shared = memory.shared_memory_dir(slug)
    shared.mkdir(exist_ok=True)
    os.chown(shared, 0, grp.getgrnam(group).gr_gid)
    os.chmod(shared, 0o2770)
    run(["setfacl", "-d", "-m", f"g:{group}:rwX", str(shared)])
    for member in members:
        entry = pwd.getpwnam(member)
        memory.link_member(entry.pw_dir, str(project["root"]), shared, entry.pw_uid, entry.pw_gid)
    run(["setfacl", "-R", "-m", f"g:{group}:rwX", str(shared)])
    return shared


def invite(slug: str, name: str, home: str, invite_key: str, share_paths: List[str]) -> Dict[str, object]:
    admin.require_root()
    slug = validate.slug(slug)
    name = validate.user(name)
    home = validate.home_path(home)
    invite_key = validate.public_key(invite_key)
    caller = admin.caller()
    project_file = paths.project_file(slug)
    with locked(project_file):
        project = admin.load_project(slug)
        if not project:
            raise admin.AdminError(f"There is no cloud project named {slug!r}.")
        if not (admin.is_admin(caller) or caller == project.get("owner")):
            raise admin.AdminError("Only the project owner can invite collaborators.")
        shares = [validate.absolute_path(path) for path in share_paths]

        created = False
        if admin.user_exists(name):
            if pwd.getpwnam(name).pw_dir != home:
                raise admin.AdminError(f"{name} already exists with a different home folder.")
        else:
            Path(home).parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            proc.run(["useradd", "--create-home", "--home-dir", home, "--shell", "/bin/bash", "--user-group", name])
            created = True
        group = paths.project_group(slug)
        admin.add_to_group(name, group)
        admin.write_sudoers(f"termuctive-member-{name}", admin.member_sudoers_rule(name))
        if admin.has_systemd():
            proc.run(["loginctl", "enable-linger", name], check=False)

        member_directory = paths.member_dir(slug, name)
        member_directory.mkdir(parents=True, exist_ok=True)
        entry = pwd.getpwnam(name)
        os.chown(member_directory, entry.pw_uid, grp.getgrnam(group).gr_gid)
        os.chmod(member_directory, 0o2755)

        members = admin.project_members(project)
        if name not in members:
            members.append(name)
        project["members"] = members
        project["sharedPaths"] = sorted(set(project.get("sharedPaths", []) or []) | set(shares))
        write_json_atomic(project_file, project, mode=0o644)

        share_project(slug, project, list(project["sharedPaths"]))
        share_memory(slug, project, members)

        invite_id = secrets.token_hex(8)
        expires = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(
            hours=INVITE_LIFETIME_HOURS
        )
        ssh_directory = Path(home) / ".ssh"
        ssh_directory.mkdir(mode=0o700, exist_ok=True)
        authorized = ssh_directory / "authorized_keys"
        line = (
            f'restrict,command="{paths.stable_tmc()} join-finish {invite_id}",'
            f'expiry-time="{expires.strftime("%Y%m%d%H%M")}Z" '
            f'{" ".join(invite_key.split()[:2])} {INVITE_MARKER}{invite_id}'
        )
        existing = authorized.read_text() if authorized.exists() else ""
        authorized.write_text(existing + line + "\n")
        for path in (ssh_directory, authorized):
            os.chown(path, entry.pw_uid, entry.pw_gid)
        os.chmod(authorized, 0o600)

        invites_dir(slug).mkdir(exist_ok=True)
        write_json_atomic(
            invites_dir(slug) / f"{invite_id}.json",
            {"member": name, "expires": expires.isoformat(), "invitedBy": caller, "created": time.time()},
            mode=0o640,
        )
    return {
        "inviteID": invite_id,
        "user": name,
        "home": home,
        "created": created,
        "expires": expires.isoformat(),
        "hostKeys": host_keys(),
        "slug": slug,
        "root": project["root"],
        "owner": project["owner"],
    }


def join_finish(invite_id: str, public_key: str) -> Dict[str, object]:
    """Runs as the invited member through the one-time invite key: installs their real
    key and removes the invite key so it cannot be used again."""
    if not invite_id.isalnum():
        raise validate.ValidationError("Invalid invite.")
    public_key = validate.public_key(public_key)
    authorized = Path(os.path.expanduser("~/.ssh/authorized_keys"))
    lines = authorized.read_text().splitlines() if authorized.exists() else []
    marker = f"{INVITE_MARKER}{invite_id}"
    if not any(line.endswith(marker) for line in lines):
        raise validate.ValidationError("This invite was already used.")
    material = " ".join(public_key.split()[:2])
    kept = [line for line in lines if not line.endswith(marker)]
    if not any(" ".join(line.split()[:2]) == material for line in kept):
        kept.append(public_key)
    authorized.write_text("\n".join(kept) + "\n")
    os.chmod(authorized, 0o600)
    # The shared repository belongs to the project owner; git refuses other owners'
    # repositories unless they are trusted.
    from . import finalize

    finalize.ensure_safe_directory()
    return {"user": proc.caller(), "home": os.path.expanduser("~")}


def team(slug: str) -> Dict[str, object]:
    slug = validate.slug(slug)
    project = admin.load_project(slug) or {}
    caller = proc.caller()
    members = []
    for member in admin.project_members(project):
        states = sessionstate.all_states(slug, member)
        members.append(
            {
                "user": member,
                "isYou": member == caller,
                "sessions": [
                    {
                        "pane": pane,
                        "cwd": state.get("cwd"),
                        "updated": state.get("updated"),
                        "claude": state.get("claude") if isinstance(state.get("claude"), dict) else None,
                    }
                    for pane, state in sorted(states.items())
                ],
            }
        )
    return {"slug": slug, "owner": project.get("owner"), "members": members}


def watch(slug: str, member: str, pane: str) -> int:
    """Shows another member's session read-only."""
    from . import tmuxctl

    slug, member, pane = validate.slug(slug), validate.user(member), validate.pane_id(pane)
    project = admin.load_project(slug) or {}
    if member not in admin.project_members(project) or proc.caller() not in admin.project_members(project):
        raise validate.ValidationError("You can only watch members of your own cloud projects.")
    socket = paths.tmux_socket(slug, member)
    if not socket.exists():
        print(f"{member} has no running sessions right now.")
        return 1
    return subprocess.call(
        tmuxctl.tmux_command(
            slug, member, "attach-session", "-f", "read-only,ignore-size", "-t", "=" + tmuxctl.session_name(pane)
        )
    )


def import_refs(root: str, member: str) -> Dict[str, str]:
    """Maps a member's pushed branches to branch names that do not overwrite others' work."""
    root = validate.absolute_path(root)
    member = validate.user(member)
    prefix = f"refs/termuctive/import/{member}/"
    listing = run(["git", "-C", root, "for-each-ref", "--format=%(refname) %(objectname)", prefix]).stdout
    checked_out = {
        line[len("branch "):]
        for line in run(["git", "-C", root, "worktree", "list", "--porcelain"]).stdout.splitlines()
        if line.startswith("branch ")
    }
    mapping: Dict[str, str] = {}
    for line in listing.splitlines():
        reference, _, commit = line.partition(" ")
        branch = reference[len(prefix):]
        target = f"refs/heads/{branch}"
        existing = run(["git", "-C", root, "rev-parse", "--verify", "--quiet", target]).stdout.strip()
        if existing and existing != commit:
            ancestor = run(["git", "-C", root, "merge-base", "--is-ancestor", existing, commit])
            # Never move a branch someone has checked out, and never rewind one.
            if ancestor.returncode != 0 or target in checked_out:
                target = f"refs/heads/{member}/{branch}"
        run(["git", "-C", root, "update-ref", target, commit])
        run(["git", "-C", root, "update-ref", "-d", reference])
        mapping[branch] = target[len("refs/heads/"):]
    return mapping
