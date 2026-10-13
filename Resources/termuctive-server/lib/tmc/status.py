"""Machine-readable server status for Termuctive's status views."""

import os
import platform
import shutil
import socket
from pathlib import Path
from typing import Dict, List, Optional

from . import PROTOCOL, VERSION, admin, paths, proc, setup, tmuxctl


def meminfo() -> Dict[str, int]:
    values: Dict[str, int] = {}
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            name, _, rest = line.partition(":")
            amount = rest.strip().split()
            if amount:
                values[name] = int(amount[0]) * 1024
    except (OSError, ValueError):
        pass
    return {
        "totalBytes": values.get("MemTotal", 0),
        "availableBytes": values.get("MemAvailable", 0),
        "swapTotalBytes": values.get("SwapTotal", 0),
        "swapFreeBytes": values.get("SwapFree", 0),
    }


def disk(path: Path) -> Dict[str, object]:
    target = path if path.exists() else Path("/")
    usage = shutil.disk_usage(target)
    return {"path": str(target), "totalBytes": usage.total, "freeBytes": usage.free}


def uptime_seconds() -> int:
    try:
        return int(float(Path("/proc/uptime").read_text().split()[0]))
    except (OSError, ValueError, IndexError):
        return 0


def os_name() -> str:
    try:
        for line in Path("/etc/os-release").read_text().splitlines():
            if line.startswith("PRETTY_NAME="):
                return line.split("=", 1)[1].strip('"')
    except OSError:
        pass
    return platform.platform()


def gpus() -> List[Dict[str, object]]:
    raw = proc.output(
        [
            "nvidia-smi",
            "--query-gpu=name,memory.total,memory.used,utilization.gpu",
            "--format=csv,noheader,nounits",
        ]
    )
    devices = []
    for line in (raw or "").splitlines():
        fields = [field.strip() for field in line.split(",")]
        if len(fields) != 4:
            continue
        try:
            devices.append(
                {
                    "name": fields[0],
                    "memoryTotalMB": int(fields[1]),
                    "memoryUsedMB": int(fields[2]),
                    "utilizationPercent": int(fields[3]),
                }
            )
        except ValueError:
            continue
    return devices


def first_line(command: List[str]) -> Optional[str]:
    output = proc.output(command)
    return output.strip().splitlines()[0] if output and output.strip() else None


def claude_path() -> Optional[str]:
    candidate = Path(os.path.expanduser("~/.local/bin/claude"))
    if candidate.exists():
        return str(candidate)
    return shutil.which("claude")


def tools() -> Dict[str, Optional[str]]:
    return {
        "tmux": first_line(["tmux", "-V"]),
        "git": first_line(["git", "--version"]),
        "node": first_line(["node", "--version"]),
        "python": platform.python_version(),
        "claude": claude_path(),
        "gh": first_line(["gh", "--version"]),
        "aws": first_line(["aws", "--version"]),
    }


def collect(slug: Optional[str] = None) -> Dict[str, object]:
    user = proc.caller()
    status: Dict[str, object] = {
        "toolkit": {"version": VERSION, "protocol": PROTOCOL},
        "user": user,
        "home": os.path.expanduser("~"),
        "hostname": socket.gethostname(),
        "os": os_name(),
        "arch": platform.machine(),
        "uptimeSeconds": uptime_seconds(),
        "load": list(os.getloadavg()),
        "cpuCount": os.cpu_count() or 0,
        "memory": meminfo(),
        "disk": disk(paths.srv_root()),
        "rebootRequired": Path("/var/run/reboot-required").exists(),
        "gpus": gpus(),
        "tailscale": setup.tailscale_status(),
        "tools": tools(),
        "projects": admin.project_list(user),
    }
    if slug:
        status["sessions"] = tmuxctl.list_sessions(slug, user)
    return status
