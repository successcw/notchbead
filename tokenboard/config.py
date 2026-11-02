"""Paths, port and device name.

Every getter reads the environment at call time so tests can point the whole
package at temporary directories with ``TOKENBOARD_*`` variables.
"""

from __future__ import annotations

import os
import socket
from pathlib import Path

APP_NAME = "tokenboard"
DEFAULT_PORT = 8787


def _env_path(name: str, default: Path) -> Path:
    value = os.environ.get(name)
    if value:
        return Path(value).expanduser()
    return default


def db_path() -> Path:
    """SQLite database location (``TOKENBOARD_DB`` overrides)."""
    return _env_path(
        "TOKENBOARD_DB",
        Path.home() / "Library" / "Application Support" / APP_NAME / "usage.db",
    )


def pi_dir() -> Path:
    """pi session logs (``TOKENBOARD_PI_DIR`` overrides)."""
    return _env_path("TOKENBOARD_PI_DIR", Path.home() / ".pi" / "agent" / "sessions")


def claude_dir() -> Path:
    """claude-code project logs (``TOKENBOARD_CLAUDE_DIR`` overrides)."""
    return _env_path("TOKENBOARD_CLAUDE_DIR", Path.home() / ".claude" / "projects")


def workbuddy_dir() -> Path:
    """WorkBuddy project logs (``TOKENBOARD_WORKBUDDY_DIR`` overrides)."""
    return _env_path(
        "TOKENBOARD_WORKBUDDY_DIR", Path.home() / ".workbuddy" / "projects"
    )


def codex_dir() -> Path:
    """codex home (``TOKENBOARD_CODEX_DIR`` overrides)."""
    return _env_path("TOKENBOARD_CODEX_DIR", Path.home() / ".codex")


def codex_sessions_dir() -> Path:
    return codex_dir() / "sessions"


def codex_archived_dir() -> Path:
    return codex_dir() / "archived_sessions"


def device() -> str:
    """Short hostname used to tag rows (``TOKENBOARD_DEVICE`` overrides)."""
    value = os.environ.get("TOKENBOARD_DEVICE")
    if value:
        return value.strip()
    return socket.gethostname().split(".")[0]


def port() -> int:
    """HTTP port for ``serve`` (``TOKENBOARD_PORT`` overrides)."""
    value = os.environ.get("TOKENBOARD_PORT")
    if value:
        try:
            return int(value)
        except ValueError:
            pass
    return DEFAULT_PORT
