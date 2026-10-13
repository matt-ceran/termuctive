"""Strict validation for every value that reaches a shell, a path or sudo."""

import posixpath
import re
import uuid

SLUG_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
USER_PATTERN = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
PATH_COMPONENT_PATTERN = re.compile(r"^[A-Za-z0-9._@+ -]+$")
PUBLIC_KEY_PATTERN = re.compile(
    r"^(ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ssh-rsa) "
    r"[A-Za-z0-9+/]+={0,3}( [A-Za-z0-9@._+-]{0,100})?$"
)
HOSTNAME_PATTERN = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")


class ValidationError(ValueError):
    pass


def slug(value: str) -> str:
    if not SLUG_PATTERN.match(value or ""):
        raise ValidationError(f"Invalid project slug: {value!r}")
    return value


def user(value: str) -> str:
    if not USER_PATTERN.match(value or "") or value in {"root", "nobody"}:
        raise ValidationError(f"Invalid user name: {value!r}")
    return value


def pane_id(value: str) -> str:
    try:
        return str(uuid.UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise ValidationError(f"Invalid pane identifier: {value!r}") from None


def hostname(value: str) -> str:
    if not HOSTNAME_PATTERN.match(value or ""):
        raise ValidationError(f"Invalid host name: {value!r}")
    return value


def absolute_path(value: str) -> str:
    """An absolute path with plain components and no traversal."""
    if not value or not value.startswith("/") or "\x00" in value or "\n" in value:
        raise ValidationError(f"Invalid path: {value!r}")
    normalized = posixpath.normpath(value)
    if normalized != value.rstrip("/") and not (value == "/" and normalized == "/"):
        raise ValidationError(f"Path is not normalized: {value!r}")
    for component in normalized.split("/")[1:]:
        if component in {"", ".", ".."} or not PATH_COMPONENT_PATTERN.match(component):
            raise ValidationError(f"Invalid path component in {value!r}")
    return normalized


def home_path(value: str) -> str:
    """Member homes mirror the Mac home folder, so /Users/<name> is allowed alongside /home."""
    path = absolute_path(value)
    parts = path.split("/")
    if len(parts) != 3 or parts[1] not in {"Users", "home"}:
        raise ValidationError(f"Home folders must be /Users/<name> or /home/<name>: {value!r}")
    return path


def public_key(value: str) -> str:
    value = (value or "").strip()
    if not PUBLIC_KEY_PATTERN.match(value):
        raise ValidationError("Invalid SSH public key")
    return value


def is_within(path: str, root: str) -> bool:
    path = posixpath.normpath(path)
    root = posixpath.normpath(root)
    return path == root or path.startswith(root.rstrip("/") + "/")
