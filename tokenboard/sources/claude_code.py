"""claude-code logs: ``~/.claude/projects/**/*.jsonl``.

One API response is written as several lines (one per content block) that all
repeat the same usage block, so ``message.id`` + ``requestId`` is the dedupe
key. ``<synthetic>`` messages are tool-generated and never billed.
"""

from __future__ import annotations

import json
from pathlib import Path

from .. import config
from ..db import normalize_model

NAME = "claude-code"
PROVIDER = "anthropic"
SYNTHETIC_MODEL = "<synthetic>"


def roots() -> list[Path]:
    return [config.claude_dir()]


def iter_files(root) -> list[Path]:
    base = Path(root)
    if not base.exists():
        return []
    return sorted(base.rglob("*.jsonl"))


def parse_file(path, device: str):
    """Yield usage rows for one claude-code project log."""
    path = Path(path)
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            raw = raw.strip()
            if not raw:
                continue
            try:
                entry = json.loads(raw)
            except (ValueError, TypeError):
                continue
            if not isinstance(entry, dict) or entry.get("type") != "assistant":
                continue
            message = entry.get("message") or {}
            if not isinstance(message, dict):
                continue
            usage = message.get("usage")
            if not isinstance(usage, dict):
                continue
            model_raw = message.get("model")
            if model_raw == SYNTHETIC_MODEL:
                continue
            details = usage.get("output_tokens_details") or {}
            message_id = message.get("id") or ""
            request_id = entry.get("requestId") or ""
            key = f"{message_id}:{request_id}" if (message_id or request_id) else (
                f"{entry.get('sessionId') or ''}:{entry.get('timestamp') or ''}"
            )
            yield {
                "id": f"{NAME}:{key}",
                "source": NAME,
                "ts": entry.get("timestamp"),
                "provider": PROVIDER,
                "model_raw": model_raw,
                "model": normalize_model(model_raw),
                "project": entry.get("cwd"),
                "session_id": entry.get("sessionId"),
                "device": device,
                "input": usage.get("input_tokens"),
                "output": usage.get("output_tokens"),
                "cache_read": usage.get("cache_read_input_tokens"),
                "cache_write": usage.get("cache_creation_input_tokens"),
                "reasoning": (
                    details.get("thinking_tokens") if isinstance(details, dict) else None
                ),
                "cost_log": None,
            }
