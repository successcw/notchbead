"""File discovery, change detection and source orchestration."""

from __future__ import annotations

import sys
import traceback
from pathlib import Path

from . import config, db
from .sources import SOURCES


def _stat(path: Path) -> tuple[int, float] | None:
    try:
        info = path.stat()
    except OSError:
        return None
    return info.st_size, info.st_mtime


def ingest_source(conn, source, device: str, log=None) -> dict:
    """Ingest one source module; return ``{scanned, changed, rows, errors}``."""
    stats = {"source": source.NAME, "scanned": 0, "changed": 0, "rows": 0, "errors": 0}
    for root in source.roots():
        for path in source.iter_files(root):
            stats["scanned"] += 1
            state = _stat(path)
            if state is None:
                stats["errors"] += 1
                _log(log, f"{source.NAME}: cannot stat {path}")
                continue
            size, mtime = state
            previous = db.file_state(conn, str(path))
            if previous is not None and previous == (size, mtime):
                continue  # unchanged since last ingest
            stats["changed"] += 1
            inserted = 0
            try:
                for row in source.parse_file(path, device):
                    row.setdefault("device", device)
                    if db.insert_event(conn, row):
                        inserted += 1
            except Exception as exc:  # a broken file must not stop the run
                stats["errors"] += 1
                _log(log, f"{source.NAME}: failed to parse {path}: {exc}")
                _log(log, traceback.format_exc(limit=3).strip())
                conn.rollback()
                continue
            db.record_file(conn, str(path), source.NAME, size, mtime)
            conn.commit()
            stats["rows"] += inserted
    return stats


def _log(log, message: str) -> None:
    if log is not None:
        log(message)
    else:
        print(message, file=sys.stderr)


def ingest(conn=None, device: str | None = None, sources=SOURCES, log=None) -> dict:
    """Ingest every source; return ``{source: stats, "rows": total, "total_rows": n}``."""
    own_conn = conn is None
    if own_conn:
        conn = db.connect()
    tag = device or config.device()
    result = {"sources": {}, "rows": 0, "scanned": 0, "changed": 0, "errors": 0}
    try:
        for source in sources:
            stats = ingest_source(conn, source, tag, log=log)
            result["sources"][source.NAME] = stats
            for key in ("rows", "scanned", "changed", "errors"):
                result[key] += stats[key]
        result["total_rows"] = db.event_count(conn)
    finally:
        if own_conn:
            conn.close()
    return result
