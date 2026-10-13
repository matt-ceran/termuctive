"""Command-line entry point: `tmc <command> ...`."""

import argparse
import sys
from typing import List, Optional

from . import (
    PROTOCOL,
    VERSION,
    admin,
    board,
    checklist,
    claudecfg,
    collab,
    doctor,
    finalize,
    hooks,
    hydrate,
    mcp,
    memory,
    ports,
    proc,
    setup,
    status,
    tmuxctl,
    validate,
)
from .jsonio import emit

EXIT_USAGE = 2


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="tmc", description="Termuctive server toolkit")
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("version", help="print the toolkit version")

    attach = commands.add_parser("attach", help="attach to a persistent pane session")
    attach.add_argument("--slug", required=True)
    attach.add_argument("--pane", required=True)
    attach.add_argument("--cwd")
    attach.add_argument("--protocol", type=int)
    attach.add_argument(
        "--command", dest="initial_command", help="run when the session is first created"
    )

    kill = commands.add_parser("kill", help="end a pane session")
    kill.add_argument("--slug", required=True)
    kill.add_argument("--pane", required=True)

    listing = commands.add_parser("list", help="list pane sessions")
    listing.add_argument("--slug", required=True)

    report = commands.add_parser("sessions", help="pane sessions with agent state")
    report.add_argument("--slug", required=True)

    hook = commands.add_parser("hook", help="Claude Code hook (reads the event on stdin)")
    hook.add_argument("event", choices=sorted(hooks.EVENTS))

    state = commands.add_parser("status", help="server status as JSON")
    state.add_argument("--slug")

    commands.add_parser("doctor", help="check the server")

    finishing = commands.add_parser("finalize", help="fix a project copied from a Mac")
    finishing.add_argument("--root", required=True)

    commands.add_parser("mkdirs", help="create folders listed on standard input")

    gitconfig = commands.add_parser("gitconfig", help="git settings copied from a Mac")
    gitconfig.add_argument("action", choices=["import"])

    claude = commands.add_parser("claude", help="Claude Code settings copied from a Mac")
    claude.add_argument("action", choices=["import-settings", "import-config", "install-hooks"])

    commands.add_parser("ports", help="TCP ports your processes listen on")

    check = commands.add_parser("checklist", help="sign-ins and setup still needed")
    check.add_argument("--root")
    check.add_argument("--json", action="store_true")

    hydration = commands.add_parser("hydrate", help="install a checkout's dependencies")
    hydration.add_argument("--root", required=True)

    finish = commands.add_parser("join-finish", help="complete an invite (reads a key on stdin)")
    finish.add_argument("invite")

    team = commands.add_parser("team", help="project members and their sessions")
    team.add_argument("--slug", required=True)

    watching = commands.add_parser("watch", help="watch another member's session read-only")
    watching.add_argument("--slug", required=True)
    watching.add_argument("--member", required=True)
    watching.add_argument("--pane", required=True)

    memories = commands.add_parser("memory", help="shared Claude memory")
    memories.add_argument("action", choices=["merge"])
    memories.add_argument("--slug", required=True)
    memories.add_argument("--from", dest="source", required=True)
    memories.add_argument("--into")

    refs = commands.add_parser("import-refs", help="adopt branches a member pushed")
    refs.add_argument("--root", required=True)

    commands.add_parser("mcp", help="Model Context Protocol server for Claude Code")

    task = commands.add_parser("task", help="the team task board")
    task.add_argument("action", choices=["post", "list", "update"])
    task.add_argument("--slug", required=True)
    task.add_argument("--to")
    task.add_argument("--title")
    task.add_argument("--details", default="")
    task.add_argument("--message", action="store_true")
    task.add_argument("--id")
    task.add_argument("--status", choices=["started", "completed", "declined"])
    task.add_argument("--result")

    autorun = commands.add_parser("autorun", help="run teammates' tasks automatically")
    autorun.add_argument("state", choices=["on", "off", "status"])
    autorun.add_argument("--slug", required=True)

    dispatcher = commands.add_parser("dispatch", help="deliver teammates' tasks to idle sessions")
    dispatcher.add_argument("--slug")
    dispatcher.add_argument("--once", action="store_true")
    dispatcher.add_argument("--interval", type=float, default=3.0)

    server = commands.add_parser("setup", help="prepare this server (root)")
    server.add_argument("--admin-user", required=True)
    server.add_argument("--member")
    server.add_argument("--member-home")
    server.add_argument("--member-key")
    server.add_argument("--hostname")
    server.add_argument("--node-major", type=int, default=22)
    server.add_argument("--container", action="store_true")
    server.add_argument("--minimal", action="store_true")
    server.add_argument("--skip-tailscale", action="store_true")
    server.add_argument("--skip-firewall", action="store_true")
    server.add_argument("--skip-gpu", action="store_true")
    server.add_argument("--skip-awscli", action="store_true")
    server.add_argument("--skip-claude", action="store_true")
    server.add_argument("--with-docker", action="store_true")

    administration = commands.add_parser("admin", help="privileged administration")
    actions = administration.add_subparsers(dest="action", required=True)
    user_add = actions.add_parser("user-add")
    user_add.add_argument("--name", required=True)
    user_add.add_argument("--home", required=True)
    user_add.add_argument("--key", required=True)
    grant = actions.add_parser("grant-admin")
    grant.add_argument("--name", required=True)
    project_create = actions.add_parser("project-create")
    project_create.add_argument("--slug", required=True)
    project_create.add_argument("--root", required=True)
    project_create.add_argument("--owner", required=True)
    actions.add_parser("project-list")
    inviting = actions.add_parser("invite")
    inviting.add_argument("--slug", required=True)
    inviting.add_argument("--name", required=True)
    inviting.add_argument("--home", required=True)
    inviting.add_argument("--invite-key", required=True)
    inviting.add_argument("--share-path", action="append", default=[])
    claude = actions.add_parser("install-claude")
    claude.add_argument("--user", required=True)
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        return dispatch(arguments)
    except (validate.ValidationError, admin.AdminError) as error:
        print(f"tmc: {error}", file=sys.stderr)
        return EXIT_USAGE
    except proc.CommandError as error:
        print(f"tmc: {error}", file=sys.stderr)
        return 1
    except ValueError as error:
        print(f"tmc: {error}", file=sys.stderr)
        return EXIT_USAGE


def dispatch(arguments: argparse.Namespace) -> int:
    command = arguments.command
    if command == "version":
        emit({"version": VERSION, "protocol": PROTOCOL})
        return 0
    if command == "attach":
        cwd = arguments.cwd
        try:
            cwd = validate.absolute_path(cwd) if cwd else None
        except validate.ValidationError:
            cwd = None
        return tmuxctl.attach(
            validate.slug(arguments.slug),
            validate.pane_id(arguments.pane),
            cwd,
            arguments.protocol,
            proc.caller(),
            arguments.initial_command,
        )
    if command == "kill":
        return tmuxctl.kill(
            validate.slug(arguments.slug), validate.pane_id(arguments.pane), proc.caller()
        )
    if command == "list":
        emit(tmuxctl.list_sessions(validate.slug(arguments.slug), proc.caller()))
        return 0
    if command == "sessions":
        emit(tmuxctl.report(validate.slug(arguments.slug), proc.caller()))
        return 0
    if command == "hook":
        try:
            return hooks.handle(arguments.event)
        except Exception:  # noqa: BLE001 - a failing hook must never disturb Claude Code
            return 0
    if command == "status":
        emit(status.collect(validate.slug(arguments.slug) if arguments.slug else None))
        return 0
    if command == "doctor":
        checks = doctor.run_checks()
        emit({"checks": checks, "ok": all(item["ok"] for item in checks)})
        return 0
    if command == "finalize":
        emit(finalize.finalize(arguments.root))
        return 0
    if command == "mkdirs":
        paths = [line for line in sys.stdin.read().splitlines() if line.strip()]
        emit({"created": finalize.make_directories(paths)})
        return 0
    if command == "gitconfig":
        emit(finalize.sanitize_gitconfig(sys.stdin.read()))
        return 0
    if command == "claude" and arguments.action == "install-hooks":
        emit(hooks.install())
        return 0
    if command == "claude":
        payload = claudecfg.parse_json_input(sys.stdin.read())
        if arguments.action == "import-settings":
            emit(claudecfg.import_settings(payload))
        else:
            emit(claudecfg.import_global_config(payload))
        return 0
    if command == "ports":
        emit(ports.own_listening_ports())
        return 0
    if command == "checklist":
        items = checklist.collect(validate.absolute_path(arguments.root) if arguments.root else None)
        if arguments.json:
            emit(items)
        else:
            print(checklist.render(items))
        return 0
    if command == "hydrate":
        return hydrate.hydrate(arguments.root)
    if command == "join-finish":
        emit(collab.join_finish(arguments.invite, sys.stdin.read()))
        return 0
    if command == "team":
        emit(collab.team(arguments.slug))
        return 0
    if command == "watch":
        return collab.watch(arguments.slug, arguments.member, arguments.pane)
    if command == "memory":
        emit(memory.merge_into_shared(arguments.slug, arguments.source, arguments.into))
        return 0
    if command == "mcp":
        return mcp.serve()
    if command == "task":
        return dispatch_task(arguments)
    if command == "autorun":
        slug = validate.slug(arguments.slug)
        if arguments.state != "status":
            board.set_auto_run(slug, proc.caller(), arguments.state == "on")
        emit({"autoRun": board.auto_run(slug, proc.caller())})
        return 0
    if command == "dispatch":
        user = proc.caller()
        if arguments.once:
            slugs = [validate.slug(arguments.slug)] if arguments.slug else board.projects_for(user)
            emit({slug: board.dispatch_once(slug, user) for slug in slugs})
            return 0
        board.dispatch_forever(user, arguments.interval)
        return 0
    if command == "import-refs":
        emit(collab.import_refs(arguments.root, proc.caller()))
        return 0
    if command == "setup":
        setup.run_setup(
            setup.SetupOptions(
                admin_user=arguments.admin_user,
                member=arguments.member,
                member_home=arguments.member_home,
                member_key=arguments.member_key,
                hostname=arguments.hostname,
                node_major=arguments.node_major,
                container=arguments.container,
                minimal=arguments.minimal,
                tailscale=not arguments.skip_tailscale,
                firewall=not arguments.skip_firewall,
                gpu=not arguments.skip_gpu,
                docker=arguments.with_docker,
                awscli=not arguments.skip_awscli,
                claude=not arguments.skip_claude,
            )
        )
        return 0
    if command == "admin":
        return dispatch_admin(arguments)
    raise AssertionError(f"unhandled command {command}")


def dispatch_task(arguments: argparse.Namespace) -> int:
    slug = validate.slug(arguments.slug)
    user = proc.caller()
    if arguments.action == "post":
        emit(
            board.post(
                slug,
                user,
                arguments.to or "",
                arguments.title or "",
                arguments.details,
                kind="message" if arguments.message else "task",
            )
        )
    elif arguments.action == "list":
        emit(board.tasks(slug))
    else:
        if not arguments.id or not arguments.status:
            raise validate.ValidationError("update needs --id and --status")
        emit(board.update(slug, user, arguments.id, arguments.status, result=arguments.result))
    return 0


def dispatch_admin(arguments: argparse.Namespace) -> int:
    action = arguments.action
    if action == "user-add":
        emit(admin.user_add(arguments.name, arguments.home, arguments.key))
    elif action == "grant-admin":
        admin.grant_admin(arguments.name)
        emit({"admin": arguments.name})
    elif action == "project-create":
        emit(admin.project_create(arguments.slug, arguments.root, arguments.owner))
    elif action == "project-list":
        emit(admin.project_list())
    elif action == "install-claude":
        emit(admin.install_claude(arguments.user))
    elif action == "invite":
        emit(
            collab.invite(
                arguments.slug,
                arguments.name,
                arguments.home,
                arguments.invite_key,
                arguments.share_path,
            )
        )
    return 0
