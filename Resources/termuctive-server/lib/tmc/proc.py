"""Process helpers that never invoke a shell with untrusted input."""

import os
import shutil
import subprocess
import sys
from typing import Dict, List, Optional, Sequence


class CommandError(RuntimeError):
    pass


def run(
    command: Sequence[str],
    *,
    check: bool = True,
    capture: bool = True,
    env: Optional[Dict[str, str]] = None,
    input_text: Optional[str] = None,
    cwd: Optional[str] = None,
) -> subprocess.CompletedProcess:
    result = subprocess.run(
        list(command),
        check=False,
        text=True,
        input=input_text,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        env=env,
        cwd=cwd,
    )
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip() if capture else ""
        raise CommandError(f"{' '.join(command)} failed ({result.returncode}): {detail}")
    return result


def output(command: Sequence[str]) -> Optional[str]:
    """Stdout of a command, or None when it is missing or fails."""
    if not shutil.which(command[0]) and not os.path.isabs(command[0]):
        return None
    try:
        result = run(command, check=False)
    except OSError:
        return None
    return result.stdout if result.returncode == 0 else None


def have(program: str) -> bool:
    return shutil.which(program) is not None


def step(message: str) -> None:
    print(f"==> {message}", flush=True)


def note(message: str) -> None:
    print(f"    {message}", flush=True)


def warn(message: str) -> None:
    print(f"!!  {message}", file=sys.stderr, flush=True)


def caller() -> str:
    """The human account behind a sudo invocation, or the current account."""
    sudo_user = os.environ.get("SUDO_USER")
    if os.geteuid() == 0 and sudo_user:
        return sudo_user
    import pwd

    return pwd.getpwuid(os.geteuid()).pw_name


def is_root() -> bool:
    return os.geteuid() == 0


def shell_lines(lines: List[str]) -> str:
    return "\n".join(lines) + "\n"
