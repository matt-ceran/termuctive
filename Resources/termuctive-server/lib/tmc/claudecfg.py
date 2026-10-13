"""Imports Claude Code settings copied from a Mac.

Commands that only exist on macOS (notification sounds, AppleScript, Homebrew
tools) are disabled rather than left to fail in every session.
"""

import json
import os
import shlex
import shutil
from pathlib import Path
from typing import Dict, List, Tuple

from .jsonio import read_json, write_json_atomic

MAC_ONLY_PROGRAMS = {"afplay", "osascript", "say", "terminal-notifier", "pbcopy", "pbpaste", "open"}


def claude_directory() -> Path:
    return Path(os.path.expanduser("~/.claude"))


def command_available(command: str) -> bool:
    try:
        words = shlex.split(command)
    except ValueError:
        return False
    for word in words:
        if "=" in word and not word.startswith(("/", "~", ".")):
            continue  # an environment assignment such as FOO=bar
        program = os.path.expanduser(word)
        if os.path.basename(program) in MAC_ONLY_PROGRAMS:
            return False
        if "/Applications/" in program or program.startswith("/opt/homebrew/"):
            return False
        if "/" in program:
            return os.path.exists(program)
        return shutil.which(program) is not None
    return False


def sanitize_hooks(hooks: Dict[str, object]) -> Tuple[Dict[str, object], List[str]]:
    kept: Dict[str, object] = {}
    disabled: List[str] = []
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            continue
        kept_groups = []
        for group in groups:
            if not isinstance(group, dict):
                continue
            entries = group.get("hooks") if isinstance(group.get("hooks"), list) else []
            kept_entries = []
            for entry in entries:
                command = entry.get("command") if isinstance(entry, dict) else None
                if (
                    isinstance(entry, dict)
                    and entry.get("type", "command") == "command"
                    and isinstance(command, str)
                    and not command_available(command)
                ):
                    disabled.append(f"{event} hook: {command}")
                    continue
                kept_entries.append(entry)
            if kept_entries:
                kept_groups.append(dict(group, hooks=kept_entries))
        if kept_groups:
            kept[event] = kept_groups
    return kept, disabled


def import_settings(mac_settings: Dict[str, object]) -> Dict[str, object]:
    settings = dict(mac_settings)
    disabled: List[str] = []
    if isinstance(settings.get("hooks"), dict):
        settings["hooks"], disabled_hooks = sanitize_hooks(settings["hooks"])
        disabled += disabled_hooks
    status_line = settings.get("statusLine")
    if isinstance(status_line, dict) and isinstance(status_line.get("command"), str):
        if not command_available(status_line["command"]):
            disabled.append(f"status line: {status_line['command']}")
            settings.pop("statusLine")

    target = claude_directory() / "settings.json"
    existing = read_json(target, {}) or {}
    # Keep hooks Termuctive manages on the server alongside the imported ones.
    managed = existing.get("hooks", {}) if isinstance(existing.get("hooks"), dict) else {}
    for event, groups in managed.items():
        termuctive_groups = [
            group
            for group in groups
            if isinstance(group, dict)
            and any(
                isinstance(entry, dict) and "/opt/termuctive/" in str(entry.get("command", ""))
                for entry in group.get("hooks", [])
            )
        ]
        if termuctive_groups:
            settings.setdefault("hooks", {}).setdefault(event, [])
            settings["hooks"][event] = [
                group
                for group in settings["hooks"][event]
                if group not in termuctive_groups
            ] + termuctive_groups

    claude_directory().mkdir(mode=0o700, parents=True, exist_ok=True)
    write_json_atomic(target, settings, mode=0o600)
    return {"path": str(target), "disabled": disabled}


def import_global_config(subset: Dict[str, object]) -> Dict[str, object]:
    """Merges per-project trust settings and user MCP servers into ~/.claude.json."""
    target = Path(os.path.expanduser("~/.claude.json"))
    config = read_json(target, {}) or {}
    projects = subset.get("projects") if isinstance(subset.get("projects"), dict) else {}
    merged_projects = config.get("projects") if isinstance(config.get("projects"), dict) else {}
    for path, settings in projects.items():
        if isinstance(path, str) and path.startswith("/") and isinstance(settings, dict):
            merged_projects[path] = {**settings, **merged_projects.get(path, {})}
    config["projects"] = merged_projects

    skipped = []
    servers = subset.get("mcpServers") if isinstance(subset.get("mcpServers"), dict) else {}
    merged_servers = config.get("mcpServers") if isinstance(config.get("mcpServers"), dict) else {}
    for name, server in servers.items():
        if not isinstance(server, dict) or name in merged_servers:
            continue
        command = server.get("command")
        if isinstance(command, str) and not command_available(command):
            skipped.append(name)
            continue
        merged_servers[name] = server
    config["mcpServers"] = merged_servers
    write_json_atomic(target, config, mode=0o600)
    return {"projects": sorted(projects), "mcpServers": sorted(merged_servers), "skipped": skipped}


def parse_json_input(text: str) -> Dict[str, object]:
    value = json.loads(text or "{}")
    if not isinstance(value, dict):
        raise ValueError("Expected a JSON object.")
    return value
