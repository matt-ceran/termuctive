"""Finds TCP ports the caller's processes are listening on, for port forwarding."""

import os
from pathlib import Path
from typing import Dict, List, Set

LISTEN_STATE = "0A"
IGNORED_PORTS = {22}


def listening_inodes() -> Dict[str, int]:
    """Maps socket inode to port for every listening TCP socket on loopback or any address."""
    inodes: Dict[str, int] = {}
    for table in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            lines = Path(table).read_text().splitlines()[1:]
        except OSError:
            continue
        for line in lines:
            fields = line.split()
            if len(fields) < 10 or fields[3] != LISTEN_STATE:
                continue
            address, _, port_hex = fields[1].rpartition(":")
            if not is_reachable_address(address):
                continue
            try:
                inodes[fields[9]] = int(port_hex, 16)
            except ValueError:
                continue
    return inodes


def is_reachable_address(address_hex: str) -> bool:
    """Loopback or wildcard listeners can be forwarded through ssh."""
    loopback = {"0100007F", "00000000000000000000000001000000"}
    wildcard = {"00000000", "00000000000000000000000000000000"}
    return address_hex in loopback or address_hex in wildcard


def own_listening_ports() -> List[Dict[str, object]]:
    inodes = listening_inodes()
    if not inodes:
        return []
    uid = os.getuid()
    found: Dict[int, Dict[str, object]] = {}
    seen: Set[int] = set()
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            if entry.stat().st_uid != uid:
                continue
            descriptors = list((entry / "fd").iterdir())
        except OSError:
            continue
        for descriptor in descriptors:
            try:
                target = os.readlink(descriptor)
            except OSError:
                continue
            if not target.startswith("socket:["):
                continue
            port = inodes.get(target[8:-1])
            if port is None or port in IGNORED_PORTS or port < 1024 or port in seen:
                continue
            seen.add(port)
            found[port] = {"port": port, "pid": int(entry.name), "command": command_name(entry)}
    return [found[port] for port in sorted(found)]


def command_name(process: Path) -> str:
    try:
        return (process / "comm").read_text().strip()
    except OSError:
        return ""
