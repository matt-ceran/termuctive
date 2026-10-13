"""Claude Code hooks that report each cloud pane's agent state to Termuctive.

Hooks fire for every Claude session of the account, so they do nothing unless the
session runs inside a Termuctive pane (TMC_PANE_ID and TMC_PROJECT are set).
"""

import json
import os
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional

from . import paths, proc, sessionstate, validate
from .jsonio import read_json, write_json_atomic

EVENTS = {
    "session-start": "SessionStart",
    "prompt": "UserPromptSubmit",
    "notification": "Notification",
    "stop": "Stop",
    "session-end": "SessionEnd",
}


def pane_context() -> Optional[Dict[str, str]]:
    pane = os.environ.get("TMC_PANE_ID", "")
    slug = os.environ.get("TMC_PROJECT", "")
    try:
        return {"pane": validate.pane_id(pane), "slug": validate.slug(slug)}
    except validate.ValidationError:
        return None


def read_event() -> Dict[str, object]:
    try:
        value = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def emit_json(payload: Dict[str, object]) -> None:
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()


def handle(event_name: str) -> int:
    context = pane_context()
    if context is None:
        return 0
    event = read_event()
    user = proc.caller()
    slug, pane = context["slug"], context["pane"]
    changes: Dict[str, object] = {}
    claude = (sessionstate.load(slug, user, pane) or {}).get("claude")
    claude = dict(claude) if isinstance(claude, dict) else {}

    if isinstance(event.get("cwd"), str):
        changes["cwd"] = event["cwd"]
    if isinstance(event.get("session_id"), str):
        claude["sessionId"] = event["session_id"]

    if event_name == "session-start":
        claude.update({"state": "idle", "ended": False, "startedAt": time.time(), "chained": 0})
    elif event_name == "prompt":
        prompt = event.get("prompt")
        claude.update({"state": "working", "ended": False, "promptAt": time.time(), "chained": 0})
        if isinstance(prompt, str):
            claude["lastPrompt"] = " ".join(prompt.split())[:200]
    elif event_name == "notification":
        kind = str(event.get("notification_type") or "")
        message = event.get("message")
        claude["state"] = "waiting" if "permission" in kind else claude.get("state", "idle")
        if kind == "idle_prompt":
            claude["state"] = "idle"
        if isinstance(message, str):
            claude["notification"] = message[:200]
        claude["notificationAt"] = time.time()
    elif event_name == "stop":
        claude.update({"state": "idle", "stoppedAt": time.time()})
    elif event_name == "session-end":
        claude.update({"state": "ended", "ended": True})
    changes["claude"] = claude
    sessionstate.update(slug, user, pane, changes)
    respond_for_team(event_name, event, slug, user, pane)
    return 0


def respond_for_team(
    event_name: str, event: Dict[str, object], slug: str, user: str, pane: str
) -> None:
    """Connects the session to teammates: context at start, handed-over work at stops."""
    from . import board, mcp

    if event_name == "session-start":
        text = mcp.team_context(slug, user)
        if text:
            emit_json(
                {
                    "hookSpecificOutput": {
                        "hookEventName": "SessionStart",
                        "additionalContext": text,
                    }
                }
            )
    elif event_name == "stop":
        state = sessionstate.load(slug, user, pane) or {}
        claude = state.get("claude") if isinstance(state.get("claude"), dict) else {}
        chained = int(claude.get("chained", 0)) if event.get("stop_hook_active") else 0
        if chained >= 3:
            return
        text = board.next_for_stop_hook(slug, user, pane)
        if text:
            claude = dict(claude, state="working", chained=chained + 1)
            sessionstate.update(slug, user, pane, {"claude": claude})
            emit_json({"decision": "block", "reason": text})


# Installing the hooks into the member's Claude settings.


def hook_groups() -> Dict[str, List[Dict[str, object]]]:
    return {
        claude_event: [
            {
                "hooks": [
                    {
                        "type": "command",
                        "command": f"{paths.stable_tmc()} hook {name}",
                        "timeout": 10,
                    }
                ]
            }
        ]
        for name, claude_event in EVENTS.items()
    }


def is_termuctive_group(group: object) -> bool:
    if not isinstance(group, dict):
        return False
    entries = group.get("hooks")
    return isinstance(entries, list) and any(
        isinstance(entry, dict) and "/bin/tmc hook " in str(entry.get("command", ""))
        for entry in entries
    )


def register_mcp_server(config_path: Optional[Path] = None) -> None:
    """Adds the termuctive tools to Claude Code for this account (user scope)."""
    target = config_path or Path(os.path.expanduser("~/.claude.json"))
    config = read_json(target, {}) or {}
    servers = config.get("mcpServers") if isinstance(config.get("mcpServers"), dict) else {}
    servers["termuctive"] = {"type": "stdio", "command": str(paths.stable_tmc()), "args": ["mcp"]}
    config["mcpServers"] = servers
    write_json_atomic(target, config, mode=0o600)


def install(settings_path: Optional[Path] = None) -> Dict[str, object]:
    register_mcp_server()
    target = settings_path or Path(os.path.expanduser("~/.claude/settings.json"))
    settings = read_json(target, {}) or {}
    hooks = settings.get("hooks") if isinstance(settings.get("hooks"), dict) else {}
    for event, groups in hook_groups().items():
        existing = hooks.get(event) if isinstance(hooks.get(event), list) else []
        hooks[event] = [group for group in existing if not is_termuctive_group(group)] + groups
    settings["hooks"] = hooks
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    write_json_atomic(target, settings, mode=0o600)
    return {"path": str(target), "events": sorted(hook_groups())}
