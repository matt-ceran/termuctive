"""The shared task board for handing work between members' agents.

Every member appends only to files in their own member folder: tasks and messages
they send go to `outbox.jsonl`, and what happens to tasks sent to them goes to
`decisions.jsonl`. Readers merge everyone's files, and a record only counts when the
file it came from belongs to the right member, so nobody can act for anyone else.
"""

import fcntl
import json
import os
import secrets
import subprocess
import time
from pathlib import Path
from typing import Dict, List, Optional

from . import admin, paths, proc, sessionstate, tmuxctl, validate
from .jsonio import read_json, write_json_atomic

OPEN_STATES = {"proposed", "queued", "delivered", "started"}
TITLE_LIMIT = 200
DETAILS_LIMIT = 20_000


def member_file(slug: str, user: str, name: str) -> Path:
    return paths.member_dir(slug, user) / name


def append(slug: str, user: str, name: str, record: Dict[str, object]) -> None:
    path = member_file(slug, user, name)
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(record, sort_keys=True) + "\n"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        os.write(descriptor, line.encode())
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def read_lines(path: Path) -> List[Dict[str, object]]:
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return []
    records = []
    for line in lines:
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(record, dict):
            records.append(record)
    return records


def members(slug: str) -> List[str]:
    return admin.project_members(admin.load_project(slug) or {})


def require_member(slug: str, user: str) -> None:
    if user not in members(slug):
        raise validate.ValidationError("You are not a member of this cloud project.")


# Writing


def post(
    slug: str,
    sender: str,
    to: str,
    title: str,
    details: str = "",
    kind: str = "task",
    to_pane: Optional[str] = None,
    from_pane: Optional[str] = None,
) -> Dict[str, object]:
    slug = validate.slug(slug)
    require_member(slug, sender)
    if to != "*" and to not in members(slug):
        raise validate.ValidationError(f"{to} is not a member of this project.")
    title = " ".join(str(title).split())[:TITLE_LIMIT]
    if not title:
        raise validate.ValidationError("A task needs a title.")
    record = {
        "id": "t" + secrets.token_hex(5),
        "kind": "message" if kind == "message" else "task",
        "to": to,
        "toPane": validate.pane_id(to_pane) if to_pane else None,
        "fromPane": validate.pane_id(from_pane) if from_pane else None,
        "title": title,
        "details": str(details)[:DETAILS_LIMIT],
        "createdAt": time.time(),
    }
    append(slug, sender, "outbox.jsonl", record)
    return dict(record, **{"from": sender, "status": "proposed"})


def decide(
    slug: str,
    user: str,
    task_id: str,
    event: str,
    pane: Optional[str] = None,
    result: Optional[str] = None,
) -> None:
    record = {"task": task_id, "event": event, "at": time.time()}
    if pane:
        record["pane"] = pane
    if result:
        record["result"] = str(result)[:DETAILS_LIMIT]
    append(slug, user, "decisions.jsonl", record)


def update(
    slug: str,
    user: str,
    task_id: str,
    status: str,
    result: Optional[str] = None,
    pane: Optional[str] = None,
) -> Dict[str, object]:
    """Records progress on a task. Only the member it was sent to may do this."""
    if status not in {"started", "completed", "declined"}:
        raise validate.ValidationError("status must be started, completed or declined.")
    task = next((t for t in tasks(slug) if t["id"] == task_id), None)
    if task is None:
        raise validate.ValidationError(f"No task {task_id}.")
    if task["from"] == user or task["to"] not in (user, "*"):
        raise validate.ValidationError("Only the teammate a task was sent to can update it.")
    if task["to"] == "*" and task.get("assignee") not in (None, user):
        raise validate.ValidationError(f"{task['assignee']} already took this task.")
    decide(slug, user, task_id, status, pane=pane, result=result)
    return {"updated": task_id, "status": status}


# Reading


def tasks(slug: str) -> List[Dict[str, object]]:
    slug = validate.slug(slug)
    everyone = members(slug)
    merged: Dict[str, Dict[str, object]] = {}
    for member in everyone:
        for record in read_lines(member_file(slug, member, "outbox.jsonl")):
            task_id = record.get("id")
            if not isinstance(task_id, str) or task_id in merged:
                continue
            merged[task_id] = dict(record, **{"from": member, "status": "proposed", "events": []})
    for member in everyone:
        for record in read_lines(member_file(slug, member, "decisions.jsonl")):
            task = merged.get(str(record.get("task")))
            if task is None:
                continue
            event = str(record.get("event"))
            is_recipient = task["to"] == member or (
                task["to"] == "*" and member != task["from"] and task.get("assignee") in (None, member)
            )
            if event == "result-delivered" and member == task["from"]:
                task["resultDelivered"] = True
                continue
            if not is_recipient:
                continue
            task["assignee"] = member
            task["events"].append(dict(record, by=member))
            if event in {"queued", "delivered", "started", "completed", "declined", "seen"}:
                task["status"] = event if event != "seen" else "completed"
            if event == "delivered" and record.get("pane"):
                task["pane"] = record["pane"]
            if event in {"completed", "declined"} and record.get("result"):
                task["result"] = record["result"]
    return sorted(merged.values(), key=lambda task: float(task.get("createdAt", 0)))


def inbox(slug: str, user: str) -> List[Dict[str, object]]:
    """Open tasks and unread messages addressed to `user`, oldest first."""
    return [
        task
        for task in tasks(slug)
        if task["from"] != user
        and (task["to"] == user or (task["to"] == "*" and task.get("assignee") in (None, user)))
        and task["status"] in ({"proposed", "queued"})
    ]


def finished_for_author(slug: str, user: str) -> List[Dict[str, object]]:
    return [
        task
        for task in tasks(slug)
        if task["from"] == user
        and task["kind"] == "task"
        and task["status"] in {"completed", "declined"}
        and not task.get("resultDelivered")
    ]


# Auto-run preference


def settings(slug: str, user: str) -> Dict[str, object]:
    value = read_json(member_file(slug, user, "settings.json"), {}) or {}
    return value if isinstance(value, dict) else {}


def auto_run(slug: str, user: str) -> bool:
    return settings(slug, user).get("autoRun", True) is not False


def set_auto_run(slug: str, user: str, enabled: bool) -> None:
    current = settings(slug, user)
    current["autoRun"] = enabled
    write_json_atomic(member_file(slug, user, "settings.json"), current, mode=0o644)


# Delivery


def prompt_for(task: Dict[str, object]) -> str:
    if task.get("kind") == "message":
        return f"[Message from {task['from']}] {task['title']}" + (
            f"\n\n{task['details']}" if task.get("details") else ""
        )
    text = f"[Task {task['id']} from {task['from']}'s agent] {task['title']}"
    if task.get("details"):
        text += f"\n\n{task['details']}"
    text += (
        f"\n\nWhen you finish, call the termuctive update_task tool with id {task['id']}, "
        "status completed and a short result. If you cannot do it, use status declined "
        "and explain why."
    )
    return text


def result_prompt(task: Dict[str, object]) -> str:
    outcome = "finished" if task["status"] == "completed" else "declined"
    return (
        f"[Task {task['id']} {outcome} by {task.get('assignee', task['to'])}] {task['title']}"
        + (f"\n\nResult: {task['result']}" if task.get("result") else "")
    )


def idle_panes(slug: str, user: str) -> List[str]:
    """The member's live panes whose Claude session is waiting for input."""
    live = {str(session["pane"]) for session in tmuxctl.list_sessions(slug, user)}
    idle = []
    for pane, state in sessionstate.all_states(slug, user).items():
        claude = state.get("claude") if isinstance(state.get("claude"), dict) else {}
        if pane in live and claude.get("state") == "idle" and not claude.get("ended"):
            idle.append(pane)
    return idle


def type_into(slug: str, user: str, pane: str, text: str) -> bool:
    """Types `text` into one of the member's own sessions and presses Return."""
    buffer_name = "termuctive-" + secrets.token_hex(4)
    load = subprocess.run(
        tmuxctl.tmux_command(slug, user, "load-buffer", "-b", buffer_name, "-"),
        input=text,
        text=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if load.returncode != 0:
        return False
    # "=name:" matches the session exactly and targets its current pane.
    target = "=" + tmuxctl.session_name(pane) + ":"
    pasted = subprocess.run(
        tmuxctl.tmux_command(slug, user, "paste-buffer", "-p", "-d", "-b", buffer_name, "-t", target),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if pasted.returncode != 0:
        return False
    time.sleep(0.3)
    entered = subprocess.run(
        tmuxctl.tmux_command(slug, user, "send-keys", "-t", target, "Enter"),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if entered.returncode == 0:
        # The pane is busy now; don't hand it a second task before its hooks catch up.
        state = sessionstate.load(slug, user, pane) or {}
        claude = dict(state.get("claude") or {}, state="working")
        sessionstate.update(slug, user, pane, {"claude": claude})
    return entered.returncode == 0


def dispatch_once(slug: str, user: str) -> Dict[str, List[str]]:
    """Runs incoming tasks in idle sessions and returns results to the sessions that asked."""
    report: Dict[str, List[str]] = {"delivered": [], "queued": [], "results": []}
    free = idle_panes(slug, user)
    if auto_run(slug, user):
        for task in inbox(slug, user):
            wanted = task.get("toPane")
            pane = wanted if wanted in free else (free[0] if free and not wanted else None)
            if pane and type_into(slug, user, str(pane), prompt_for(task)):
                decide(slug, user, str(task["id"]), "delivered", pane=str(pane))
                free.remove(pane)
                report["delivered"].append(str(task["id"]))
            elif task["status"] == "proposed":
                decide(slug, user, str(task["id"]), "queued")
                report["queued"].append(str(task["id"]))
    for task in finished_for_author(slug, user):
        pane = task.get("fromPane")
        if pane in free and type_into(slug, user, str(pane), result_prompt(task)):
            decide(slug, user, str(task["id"]), "result-delivered")
            free.remove(pane)
            report["results"].append(str(task["id"]))
    return report


def next_for_stop_hook(slug: str, user: str, pane: str) -> Optional[str]:
    """When a session finishes a turn, hand it the next queued task or a finished
    task's result. Returns the text to continue with, or None."""
    if auto_run(slug, user):
        for task in inbox(slug, user):
            wanted = task.get("toPane")
            if wanted and wanted != pane:
                continue
            decide(slug, user, str(task["id"]), "delivered", pane=pane)
            return prompt_for(task)
    for task in finished_for_author(slug, user):
        if task.get("fromPane") in (None, pane):
            decide(slug, user, str(task["id"]), "result-delivered")
            return result_prompt(task)
    return None


def projects_for(user: str) -> List[str]:
    return [str(project["slug"]) for project in admin.project_list(user) if user in admin.project_members(project)]


def dispatch_forever(user: str, interval: float) -> None:
    while True:
        for slug in projects_for(user):
            try:
                dispatch_once(slug, user)
            except Exception as error:  # noqa: BLE001 - one bad project must not stop the rest
                proc.warn(f"{slug}: {error}")
        time.sleep(interval)
