"""codex logs: ``~/.codex/sessions/**/*.jsonl`` and ``~/.codex/archived_sessions``.

Preferred usage rows are ``token_usage_record`` lines keyed by ``response_id``.
Only files without any ``token_usage_record`` fall back to ``token_count``
events (the cumulative counter repeats, so repeats are skipped). Archived files
are zstd-compressed and are streamed through ``zstd -dc``.
"""

from __future__ import annotations

import io
import json
import subprocess
from pathlib import Path

from .. import config
from ..db import normalize_model

NAME = "codex"
DEFAULT_PROVIDER = "openai"
# SPEC: both codex roots are read recursively for plain and zstd-compressed rollouts;
# Codex compresses older rollouts in place, so sessions/ holds *.jsonl.zst too.
PATTERNS = ("*.jsonl", "*.jsonl.zst")


def roots() -> list[Path]:
    return [config.codex_sessions_dir(), config.codex_archived_dir()]


def iter_files(root) -> list[Path]:
    base = Path(root)
    if not base.exists():
        return []
    found: list[Path] = []
    for pattern in PATTERNS:
        found.extend(base.rglob(pattern))
    return sorted(set(found))


class ArchiveReadError(RuntimeError):
    """Raised when ``zstd`` cannot fully decode a compressed rollout."""


def open_lines(path):
    """Yield text lines from a plain or zstd-compressed log file.

    For ``.zst`` the decompressor's exit status is checked after the stream is
    drained: a truncated or corrupt archive must raise instead of silently
    yielding half a file, so that ingest rolls this file back and retries it on
    the next run.
    """
    path = Path(path)
    if path.suffix != ".zst":
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            yield from handle
        return

    process = subprocess.Popen(
        ["zstd", "-dc", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stream = io.TextIOWrapper(process.stdout, encoding="utf-8", errors="replace")
    status = {"returncode": None, "stderr": b""}
    try:
        yield from stream
    finally:
        try:
            stream.close()
        finally:
            if process.stderr is not None:
                try:
                    status["stderr"] = process.stderr.read() or b""
                finally:
                    process.stderr.close()
            status["returncode"] = process.wait()
    # Reached only when the archive was drained completely.
    if status["returncode"]:
        detail = status["stderr"].decode("utf-8", "replace").strip()[:200]
        raise ArchiveReadError(
            f"zstd -dc failed for {path} (exit {status['returncode']}): "
            f"{detail or 'no stderr output'}"
        )


def _counts(usage: dict) -> dict:
    """Map a codex usage block onto usage_events counters."""
    input_tokens = int(usage.get("input_tokens") or 0)
    cached = int(usage.get("cached_input_tokens") or 0)
    return {
        "input": max(input_tokens - cached, 0),
        "output": int(usage.get("output_tokens") or 0),
        "cache_read": cached,
        "cache_write": int(usage.get("cache_write_input_tokens") or 0),
        "reasoning": int(usage.get("reasoning_output_tokens") or 0),
    }


def _totals_signature(total: dict) -> tuple:
    return tuple(sorted((str(k), v) for k, v in total.items()))


def parse_file(path, device: str):
    """Yield usage rows for one codex rollout file (plain or ``.zst``)."""
    path = Path(path)
    session_id = None
    project = None
    provider = DEFAULT_PROVIDER
    model_raw = None
    seen_record = False
    fallback_rows: list[dict] = []
    previous_total = None

    for raw in open_lines(path):
        raw = raw.strip()
        if not raw:
            continue
        try:
            entry = json.loads(raw)
        except (ValueError, TypeError):
            continue
        if not isinstance(entry, dict):
            continue
        etype = entry.get("type")
        payload = entry.get("payload") or {}
        if not isinstance(payload, dict):
            payload = {}
        ts = entry.get("timestamp")

        if etype == "session_meta":
            session_id = payload.get("id") or payload.get("session_id") or session_id
            project = payload.get("cwd") or project
            provider = payload.get("model_provider") or provider
            continue

        if etype == "turn_context":
            model_raw = payload.get("model") or model_raw
            project = project or payload.get("cwd")
            continue

        if etype == "token_usage_record":
            # The presence of the record type alone disables the token_count
            # fallback, even when this particular payload is unusable.
            seen_record = True
            usage = payload.get("usage")
            if not isinstance(usage, dict):
                continue
            response_id = payload.get("response_id") or (
                f"{session_id or path.stem}:{ts}"
            )
            yield {
                "id": f"{NAME}:{response_id}",
                "source": NAME,
                "ts": ts,
                "provider": provider,
                "model_raw": model_raw,
                "model": normalize_model(model_raw),
                "project": project,
                "session_id": session_id,
                "device": device,
                "cost_log": None,
                **_counts(usage),
            }
            continue

        if etype == "event_msg" and payload.get("type") == "token_count":
            info = payload.get("info")
            if not isinstance(info, dict):
                continue
            total = info.get("total_token_usage")
            last = info.get("last_token_usage")
            if not isinstance(total, dict) or not isinstance(last, dict):
                continue
            signature = _totals_signature(total)
            if signature == previous_total:
                # The cumulative counter repeats; this event adds nothing.
                continue
            previous_total = signature
            total_tokens = total.get("total_tokens")
            fallback_rows.append(
                {
                    "id": f"{NAME}:{session_id or path.stem}:tc:{total_tokens}",
                    "source": NAME,
                    "ts": ts,
                    "provider": provider,
                    "model_raw": model_raw,
                    "model": normalize_model(model_raw),
                    "project": project,
                    "session_id": session_id,
                    "device": device,
                    "cost_log": None,
                    **_counts(last),
                }
            )
            continue

    # Fallback rows are only valid for files that never logged token_usage_record.
    if not seen_record:
        yield from fallback_rows
