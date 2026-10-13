"""A Model Context Protocol server that lets Claude Code hand work to teammates.

Claude Code starts it over stdio. It speaks newline-delimited JSON-RPC 2.0 and offers
tools to see the team, post tasks and messages, and report progress on tasks.
"""

import json
import os
import sys
from typing import Dict, List, Optional

from . import VERSION, admin, board, collab, proc, validate

SUPPORTED_PROTOCOLS = ["2025-06-18", "2025-03-26", "2024-11-05"]

TOOLS = [
    {
        "name": "team_status",
        "description": (
            "Shows who works on this cloud project, what each of their Claude sessions is "
            "doing, and open tasks. Use it before handing work to a teammate."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "post_task",
        "description": (
            "Hands a task to a teammate's agents. It runs automatically in one of their idle "
            "Claude sessions (or the next one to finish), and its result comes back to this "
            "session. Write the details so another agent can do it without this conversation."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "to": {"type": "string", "description": "Teammate's account name, or * for anyone"},
                "title": {"type": "string", "description": "One line describing the task"},
                "details": {"type": "string", "description": "Everything needed to do it"},
                "pane": {"type": "string", "description": "Optional: a specific session id"},
            },
            "required": ["to", "title"],
        },
    },
    {
        "name": "list_tasks",
        "description": "Lists tasks on the board: sent by you, for you, or all open ones.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "filter": {"type": "string", "enum": ["mine", "sent", "open", "all"]},
            },
        },
    },
    {
        "name": "update_task",
        "description": (
            "Reports on a task you received: started, completed (with a short result), or "
            "declined (with the reason)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {"type": "string"},
                "status": {"type": "string", "enum": ["started", "completed", "declined"]},
                "result": {"type": "string"},
            },
            "required": ["id", "status"],
        },
    },
    {
        "name": "send_message",
        "description": "Sends a short note to a teammate's idle session, without asking for work.",
        "inputSchema": {
            "type": "object",
            "properties": {"to": {"type": "string"}, "text": {"type": "string"}},
            "required": ["to", "text"],
        },
    },
]


class ToolError(Exception):
    pass


def context() -> Dict[str, Optional[str]]:
    user = proc.caller()
    slug = os.environ.get("TMC_PROJECT")
    pane = os.environ.get("TMC_PANE_ID")
    if not slug:
        cwd = os.getcwd()
        for project in admin.project_list(user):
            if validate.is_within(cwd, str(project.get("root", ""))):
                slug = str(project["slug"])
                break
    if not slug:
        raise ToolError("This session is not inside a Termuctive cloud project.")
    return {"user": user, "slug": validate.slug(slug), "pane": pane}


def summarize(task: Dict[str, object]) -> Dict[str, object]:
    keys = ["id", "kind", "from", "to", "title", "status", "assignee", "result", "createdAt"]
    return {key: task.get(key) for key in keys if task.get(key) is not None}


def call(name: str, arguments: Dict[str, object]) -> object:
    where = context()
    user, slug, pane = str(where["user"]), str(where["slug"]), where["pane"]
    if name == "team_status":
        report = collab.team(slug)
        report["openTasks"] = [
            summarize(task) for task in board.tasks(slug) if task["status"] in board.OPEN_STATES
        ]
        report["you"] = user
        report["autoRun"] = board.auto_run(slug, user)
        return report
    if name == "post_task":
        task = board.post(
            slug,
            user,
            str(arguments.get("to", "")),
            str(arguments.get("title", "")),
            str(arguments.get("details", "")),
            to_pane=arguments.get("pane") or None,
            from_pane=pane,
        )
        return {"posted": summarize(task)}
    if name == "send_message":
        message = board.post(
            slug, user, str(arguments.get("to", "")), str(arguments.get("text", "")),
            kind="message", from_pane=pane,
        )
        return {"sent": summarize(message)}
    if name == "list_tasks":
        selection = arguments.get("filter", "open")
        tasks = board.tasks(slug)
        if selection == "mine":
            tasks = [t for t in tasks if t["to"] in (user, "*") and t["from"] != user]
        elif selection == "sent":
            tasks = [t for t in tasks if t["from"] == user]
        elif selection == "open":
            tasks = [t for t in tasks if t["status"] in board.OPEN_STATES]
        return {"tasks": [summarize(task) for task in tasks]}
    if name == "update_task":
        return board.update(
            slug,
            user,
            str(arguments.get("id", "")),
            str(arguments.get("status", "")),
            result=arguments.get("result"),
            pane=pane,
        )
    raise ToolError(f"Unknown tool {name}.")


def respond(message_id: object, result: Optional[object] = None, error: Optional[Dict] = None) -> None:
    payload: Dict[str, object] = {"jsonrpc": "2.0", "id": message_id}
    if error is not None:
        payload["error"] = error
    else:
        payload["result"] = result if result is not None else {}
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def handle(message: Dict[str, object]) -> None:
    method = message.get("method")
    message_id = message.get("id")
    if message_id is None:
        return  # notifications need no reply
    if method == "initialize":
        params = message.get("params") or {}
        requested = params.get("protocolVersion") if isinstance(params, dict) else None
        version = requested if requested in SUPPORTED_PROTOCOLS else SUPPORTED_PROTOCOLS[0]
        respond(
            message_id,
            {
                "protocolVersion": version,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "termuctive", "version": VERSION},
                "instructions": (
                    "Termuctive connects the agents of everyone working on this cloud project. "
                    "Use team_status to see teammates and post_task to hand them work."
                ),
            },
        )
    elif method == "ping":
        respond(message_id, {})
    elif method == "tools/list":
        respond(message_id, {"tools": TOOLS})
    elif method == "tools/call":
        params = message.get("params") or {}
        name = params.get("name") if isinstance(params, dict) else None
        arguments = params.get("arguments") if isinstance(params, dict) else None
        try:
            result = call(str(name), arguments if isinstance(arguments, dict) else {})
            respond(
                message_id,
                {"content": [{"type": "text", "text": json.dumps(result, indent=2, default=str)}]},
            )
        except (ToolError, validate.ValidationError, admin.AdminError) as error:
            respond(message_id, {"content": [{"type": "text", "text": str(error)}], "isError": True})
    else:
        respond(message_id, error={"code": -32601, "message": f"Unknown method {method}"})


def serve() -> int:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            respond(None, error={"code": -32700, "message": "Parse error"})
            continue
        if isinstance(message, dict):
            handle(message)
    return 0


def team_context(slug: str, user: str) -> str:
    """Text added to every new Claude session in a shared cloud project."""
    others = [member for member in board.members(slug) if member != user]
    if not others:
        return ""
    return (
        f"You are working in a shared Termuctive cloud project with {', '.join(others)}. "
        "Their Claude sessions work on the same code at the same time. Use the termuctive "
        "tools to coordinate: team_status shows what everyone is doing, post_task hands a "
        "self-contained task to a teammate's agents (it runs automatically and the result "
        "returns here), and update_task reports on tasks you receive. Avoid editing files a "
        "teammate's session is working on; work in your own worktree or branch."
    )
