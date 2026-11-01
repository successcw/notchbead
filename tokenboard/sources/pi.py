"""pi session logs: ``~/.pi/agent/sessions/**/*.jsonl``.

Line 1 is a session header; every later ``message`` entry from the assistant
that carries a ``usage`` block is one usage row. Forked sessions copy parent
entries with the same ``id`` + ``timestamp``, so that pair is the dedupe key.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from .. import config
from ..db import normalize_model

NAME = "pi"


def roots() -> list[Path]:
    return [config.pi_dir()]


def iter_files(root) -> "list[Path]":
    base = Path(root)
    if not base.exists():
        return []
    return sorted(base.rglob("*.jsonl"))


def _dedupe_key(entry: dict, raw: str) -> str:
    entry_id = entry.get("id")
    ts = entry.get("timestamp")
    if entry_id or ts:
        return f"{entry_id or ''}:{ts or ''}"
    # No stable identity in the log line: hash it so rows never collapse.
    return "sha1:" + hashlib.sha1(raw.encode("utf-8", "replace")).hexdigest()[:16]


def parse_file(path, device: str):
    """Yield usage rows for one pi session file."""
    path = Path(path)
    session_id = None
    project = None
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        first_line = handle.readline()
        if not first_line:
            return
        try:
            header = json.loads(first_line)
        except (ValueError, TypeError):
            return
        if not isinstance(header, dict) or header.get("type") != "session":
            return
        session_id = header.get("id")
        project = header.get("cwd")

        for raw in handle:
            raw = raw.strip()
            if not raw:
                continue
            try:
                entry = json.loads(raw)
            except (ValueError, TypeError):
                continue
            if not isinstance(entry, dict):
                continue
            if entry.get("type") != "message":
                continue
            message = entry.get("message") or {}
            if not isinstance(message, dict) or message.get("role") != "assistant":
                continue
            usage = message.get("usage")
            if not isinstance(usage, dict):
                continue
            cost = usage.get("cost") or {}
            model_raw = message.get("model")
            yield {
                "id": f"{NAME}:{_dedupe_key(entry, raw)}",
                "source": NAME,
                "ts": entry.get("timestamp"),
                "provider": message.get("provider"),
                "model_raw": model_raw,
                "model": normalize_model(model_raw),
                "project": project,
                "session_id": session_id,
                "device": device,
                "input": usage.get("input"),
                "output": usage.get("output"),
                "cache_read": usage.get("cacheRead"),
                "cache_write": usage.get("cacheWrite"),
                "reasoning": usage.get("reasoning"),
                "cost_log": cost.get("total") if isinstance(cost, dict) else None,
            }
