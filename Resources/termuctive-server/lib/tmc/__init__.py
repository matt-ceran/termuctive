"""Termuctive server toolkit.

Installed on a Termuctive cloud server and invoked by the Termuctive app over SSH.
Only the Python standard library is used so a fresh Ubuntu server can run it.
"""

from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent.parent


def _read(name: str, default: str) -> str:
    try:
        return (_ROOT / name).read_text().strip() or default
    except OSError:
        return default


VERSION = _read("VERSION", "0.0.0")
PROTOCOL = int(_read("PROTOCOL", "1"))
TOOLKIT_ROOT = _ROOT
