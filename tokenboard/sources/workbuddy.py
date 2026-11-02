"""WorkBuddy logs: ``~/.workbuddy/projects/**/*.jsonl``.

One JSON object per line, Codex/OpenAI-agents style. A usage row is any line
whose ``providerData.rawUsage`` is a dict (in practice ``function_call`` and
assistant ``message`` lines). ``prompt_tokens`` already *includes* cache reads
and cache writes, so the uncached input is the remainder.

Paths under a ``tool-results`` directory are tool output, not conversations,
and are skipped.

Dedupe key: ``messageId`` plus the token pair. The same ``messageId`` sometimes
covers two separate calls with different usage - both must count - while an
identical copy of one call must collapse.
"""

from __future__ import annotations

import datetime as _dt
import hashlib
import json
import math
from pathlib import Path

from .. import config
from ..db import normalize_model

NAME = "workbuddy"
PROVIDER = "workbuddy"
SKIP_DIRS = {"tool-results"}


def roots() -> list[Path]:
    return [config.workbuddy_dir()]


def iter_files(root) -> list[Path]:
    """Recursive ``*.jsonl`` under *root*, skipping ``tool-results`` subtrees."""
    base = Path(root)
    if not base.exists():
        return []
    found: list[Path] = []
    for path in base.rglob("*.jsonl"):
        if SKIP_DIRS.intersection(path.relative_to(base).parts[:-1]):
            continue
        found.append(path)
    return sorted(found)


_INT64_MAX = 2**63 - 1


def _num(value) -> int:
    """A counter, with missing/None/non-numeric/infinite treated as 0."""
    if isinstance(value, bool) or value is None:
        return 0
    if isinstance(value, (int, float)):
        try:
            if isinstance(value, float) and not math.isfinite(value):
                return 0  # json 1e309 -> inf, NaN from a broken log line
            return min(max(int(value), 0), _INT64_MAX)
        except (OverflowError, ValueError):
            return 0
    try:
        number = int(str(value).strip())
    except (TypeError, ValueError, OverflowError):
        return 0
    return min(max(number, 0), _INT64_MAX)


def _peak(*values) -> int:
    return max((_num(v) for v in values), default=0)


def iso_from_ms(value) -> str | None:
    """Epoch milliseconds -> ``YYYY-MM-DDTHH:MM:SS.mmmZ`` (None when invalid)."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        moment = _dt.datetime.fromtimestamp(float(value) / 1000.0, tz=_dt.UTC)
    except (OverflowError, OSError, ValueError):
        return None
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + f"{moment.microsecond // 1000:03d}Z"


def _mapping(raw_usage: dict) -> dict:
    """Map a ``rawUsage`` block onto usage_events counters."""
    prompt = _num(raw_usage.get("prompt_tokens"))
    prompt_details = raw_usage.get("prompt_tokens_details") or {}
    if not isinstance(prompt_details, dict):
        prompt_details = {}
    completion_details = raw_usage.get("completion_tokens_details") or {}
    if not isinstance(completion_details, dict):
        completion_details = {}

    cache_read = _peak(
        raw_usage.get("prompt_cache_hit_tokens"),
        raw_usage.get("cache_read_input_tokens"),
        prompt_details.get("cached_tokens"),
        raw_usage.get("cached_tokens"),
    )
    cache_write = _peak(
        raw_usage.get("cache_creation_input_tokens"),
        raw_usage.get("prompt_cache_write_tokens"),
    )
    input_tokens = max(0, prompt - cache_read - cache_write)
    # An explicit reasoning_tokens (even 0) wins; only a missing/None key falls
    # back to the older completion_thinking_tokens field.
    if completion_details.get("reasoning_tokens") is not None:
        reasoning = _num(completion_details.get("reasoning_tokens"))
    else:
        reasoning = _num(raw_usage.get("completion_thinking_tokens"))
    return {
        "input": input_tokens,
        "output": _num(raw_usage.get("completion_tokens")),
        "cache_read": cache_read,
        "cache_write": cache_write,
        "reasoning": reasoning,
    }


def _row_id(provider_data: dict, raw_usage: dict, line: str) -> str:
    message_id = provider_data.get("messageId")
    if isinstance(message_id, str) and message_id.strip():
        return (
            f"{NAME}:{message_id.strip()}:"
            f"{_num(raw_usage.get('prompt_tokens'))}:"
            f"{_num(raw_usage.get('completion_tokens'))}"
        )
    digest = hashlib.sha1(line.encode("utf-8", "replace")).hexdigest()[:16]
    return f"{NAME}:sha1:{digest}"


def parse_file(path, device: str):
    """Yield usage rows for one WorkBuddy session file."""
    path = Path(path)
    meta_session_id = None
    project = None
    pending: list[dict] = []  # rows wait until the file's first cwd is known

    with path.open("r", encoding="utf-8", errors="replace") as handle:
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

            # The session-meta id is remembered separately: a row only uses it
            # when the row itself has no sessionId (rows never inherit the
            # sessionId of an unrelated earlier line).
            if entry.get("type") == "session-meta":
                payload = entry.get("payload")
                meta = payload if isinstance(payload, dict) else entry
                for key in ("sessionId", "session_id", "id"):
                    value = meta.get(key)
                    if isinstance(value, str) and value.strip():
                        meta_session_id = value.strip()
                        break
            line_session = entry.get("sessionId")
            if not (isinstance(line_session, str) and line_session.strip()):
                line_session = None

            cwd = entry.get("cwd")
            if project is None and isinstance(cwd, str) and cwd.strip():
                project = cwd.strip()

            provider_data = entry.get("providerData")
            if not isinstance(provider_data, dict):
                continue
            raw_usage = provider_data.get("rawUsage")
            if not isinstance(raw_usage, dict):
                continue
            ts = iso_from_ms(entry.get("timestamp"))
            if ts is None:
                continue  # a row without a usable timestamp cannot be placed

            model_raw = provider_data.get("model")
            if not isinstance(model_raw, str) or not model_raw.strip():
                model_raw = provider_data.get("requestModelId")
            if not isinstance(model_raw, str) or not model_raw.strip():
                model_raw = None

            pending.append(
                {
                    "id": _row_id(provider_data, raw_usage, raw),
                    "source": NAME,
                    "ts": ts,
                    "provider": PROVIDER,
                    "model_raw": model_raw,
                    "model": normalize_model(model_raw),
                    "project": None,  # filled below
                    "session_id": line_session and line_session.strip(),
                    "device": device,
                    "cost_log": None,
                    **_mapping(raw_usage),
                }
            )

    fallback_session = meta_session_id or path.stem
    for row in pending:
        row["project"] = project
        # own sessionId -> session-meta sessionId -> file stem
        row["session_id"] = row["session_id"] or fallback_session
        yield row
