"""SQLite schema, connection, insert and query helpers.

The database is the long-term record: raw agent logs are deleted by the tools
over time, so ingest must be idempotent and rows are never rewritten.
"""

from __future__ import annotations

import datetime as _dt
import sqlite3
from pathlib import Path

from . import config, pricing

SCHEMA_VERSION = 2  # bump when stored rows must be repaired by a full re-parse

SCHEMA = """
CREATE TABLE IF NOT EXISTS usage_events (
  id          TEXT PRIMARY KEY,
  source      TEXT NOT NULL,
  ts          TEXT NOT NULL,
  provider    TEXT,
  model_raw   TEXT,
  model       TEXT,
  project     TEXT,
  session_id  TEXT,
  device      TEXT NOT NULL,
  input       INTEGER NOT NULL DEFAULT 0,
  output      INTEGER NOT NULL DEFAULT 0,
  cache_read  INTEGER NOT NULL DEFAULT 0,
  cache_write INTEGER NOT NULL DEFAULT 0,
  reasoning   INTEGER NOT NULL DEFAULT 0,
  cost_log    REAL
);
CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage_events(ts);
CREATE TABLE IF NOT EXISTS ingested_files (
  path TEXT PRIMARY KEY, source TEXT NOT NULL, size INTEGER, mtime REAL, ingested_at TEXT
);
"""

EVENT_COLUMNS = (
    "id",
    "source",
    "ts",
    "provider",
    "model_raw",
    "model",
    "project",
    "session_id",
    "device",
    "input",
    "output",
    "cache_read",
    "cache_write",
    "reasoning",
    "cost_log",
)

# Cost is resolved by a Python UDF (logged cost, else pricing.json, else NULL) so
# the CLI and the HTTP API share exactly one rule. Connections are created by
# connect(), which registers the function.
COST_EXPR = "row_cost(cost_log, model, input, output, cache_read, cache_write)"
UNKNOWN_COST_EXPR = f"({COST_EXPR}) IS NULL"

# metric key -> SQL expression over a single usage_events row.
METRIC_SQL = {
    "total": "input + output + cache_read + cache_write",
    "io": "input + output",
    "input": "input",
    "output": "output",
    "cost": f"COALESCE({COST_EXPR}, 0.0)",
}

BREAKDOWN_KEYS = {
    "source": "source",
    "model": "COALESCE(model, model_raw)",
    "device": "device",
    "project": "project",
}


def normalize_model(model_raw: str | None) -> str | None:
    """Normalize a logged model string: part after the last '/', lowercase, trimmed."""
    if not model_raw:
        return None
    return model_raw.rsplit("/", 1)[-1].strip().lower() or None


def connect(path: str | Path | None = None) -> sqlite3.Connection:
    """Open (creating if needed) the usage database and ensure the schema."""
    target = Path(path) if path is not None else config.db_path()
    if str(target) != ":memory:":
        target.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(target))
    conn.row_factory = sqlite3.Row
    init_schema(conn)
    pricing.register_cost_function(conn, pricing.load_pricing())
    return conn


def init_schema(conn: sqlite3.Connection) -> None:
    """Create tables and upgrade older databases in place.

    ``PRAGMA user_version`` tracks the data-layer version. On upgrade the
    ``ingested_files`` markers are invalidated (never deleted) so every log is
    re-parsed once: that repairs rows written by older parsers, e.g. duplicate
    ids that kept the wrong timestamp. ``usage_events`` itself is never
    touched, so no history is lost when the DB is upgraded.
    """
    conn.executescript(SCHEMA)
    version = int(conn.execute("PRAGMA user_version").fetchone()[0])
    if version != SCHEMA_VERSION:
        conn.execute("UPDATE ingested_files SET size = -1, mtime = -1")
        conn.execute(f"PRAGMA user_version = {int(SCHEMA_VERSION)}")
    conn.commit()


def _as_int(value) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def _as_float(value):
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def is_empty_row(row: dict) -> bool:
    """True when all four token counters are zero (such rows are not stored)."""
    return not any(
        _as_int(row.get(key)) for key in ("input", "output", "cache_read", "cache_write")
    )


def insert_event(conn: sqlite3.Connection, row: dict) -> bool:
    """Insert one usage row; return True when a new row was written."""
    if is_empty_row(row):
        return False
    values = (
        row.get("id"),
        row.get("source"),
        row.get("ts"),
        row.get("provider"),
        row.get("model_raw"),
        row.get("model") or normalize_model(row.get("model_raw")),
        row.get("project"),
        row.get("session_id"),
        row.get("device") or config.device(),
        _as_int(row.get("input")),
        _as_int(row.get("output")),
        _as_int(row.get("cache_read")),
        _as_int(row.get("cache_write")),
        _as_int(row.get("reasoning")),
        _as_float(row.get("cost_log")),
    )
    cur = conn.execute(
        f"INSERT OR IGNORE INTO usage_events ({', '.join(EVENT_COLUMNS)}) "
        f"VALUES ({', '.join('?' * len(EVENT_COLUMNS))})",
        values,
    )
    if cur.rowcount > 0:
        return True
    # Duplicate id (e.g. a resumed session re-emits an event with a later
    # timestamp): keep the earliest ts so daily totals do not depend on the
    # order files happen to be walked in. A ts repair is not a new row.
    conn.execute(
        "UPDATE usage_events SET ts = ? WHERE id = ? AND julianday(?) < julianday(ts)",
        (row.get("ts"), row.get("id"), row.get("ts")),
    )
    return False


def event_count(conn: sqlite3.Connection) -> int:
    return int(conn.execute("SELECT COUNT(*) FROM usage_events").fetchone()[0])


def file_state(conn: sqlite3.Connection, path: str) -> tuple[int, float] | None:
    """Previously recorded ``(size, mtime)`` for a log file, or None."""
    row = conn.execute(
        "SELECT size, mtime FROM ingested_files WHERE path = ?", (str(path),)
    ).fetchone()
    if row is None:
        return None
    return int(row["size"] or 0), float(row["mtime"] or 0.0)


def record_file(
    conn: sqlite3.Connection, path: str, source: str, size: int, mtime: float
) -> None:
    conn.execute(
        "INSERT INTO ingested_files (path, source, size, mtime, ingested_at) "
        "VALUES (?, ?, ?, ?, ?) "
        "ON CONFLICT(path) DO UPDATE SET source=excluded.source, size=excluded.size, "
        "mtime=excluded.mtime, ingested_at=excluded.ingested_at",
        (str(path), source, int(size), float(mtime), _dt.datetime.now(_dt.UTC).isoformat()),
    )


def local_today() -> _dt.date:
    return _dt.datetime.now().astimezone().date()


def day_range(start: str, end: str) -> list[str]:
    """Inclusive list of ``YYYY-MM-DD`` strings between start and end."""
    first = _dt.date.fromisoformat(start)
    last = _dt.date.fromisoformat(end)
    days = []
    cursor = first
    while cursor <= last:
        days.append(cursor.isoformat())
        cursor += _dt.timedelta(days=1)
    return days


def _metric_expr(metric: str) -> str:
    try:
        return METRIC_SQL[metric]
    except KeyError:
        raise ValueError(
            f"unknown metric {metric!r}, expected one of {sorted(METRIC_SQL)}"
        ) from None


def sources_in_db(conn: sqlite3.Connection) -> list[str]:
    rows = conn.execute(
        "SELECT DISTINCT source FROM usage_events ORDER BY source"
    ).fetchall()
    return [row["source"] for row in rows]


def query_daily(
    conn: sqlite3.Connection, start: str, end: str, metric: str = "total"
) -> dict:
    """Day x source series; every day in range is present (zeros when empty).

    For ``metric="cost"`` the result also carries ``cost_partial`` (some rows in
    range have no known price) and ``cost_unknown_rows`` so callers can warn
    that the total only covers priced models.
    """
    expr = _metric_expr(metric)
    rows = conn.execute(
        f"SELECT date(ts, 'localtime') AS day, source, SUM({expr}) AS value "
        "FROM usage_events WHERE date(ts, 'localtime') BETWEEN ? AND ? "
        "GROUP BY day, source ORDER BY day",
        (start, end),
    ).fetchall()
    days = day_range(start, end)
    sources = sorted({row["source"] for row in rows}) or sources_in_db(conn)
    series = {source: [0.0 if metric == "cost" else 0] * len(days) for source in sources}
    index = {day: i for i, day in enumerate(days)}
    for row in rows:
        series[row["source"]][index[row["day"]]] = _round(row["value"], metric)
    result = {
        "days": days,
        "series": series,
        "metric": metric,
        "sources": sources,
    }
    if metric == "cost":
        counts = conn.execute(
            f"SELECT SUM(CASE WHEN {UNKNOWN_COST_EXPR} THEN 1 ELSE 0 END) AS unknown_rows, "
            f"SUM(CASE WHEN {UNKNOWN_COST_EXPR} THEN 0 ELSE 1 END) AS known_rows "
            "FROM usage_events WHERE date(ts, 'localtime') BETWEEN ? AND ?",
            (start, end),
        ).fetchone()
        result["cost_unknown_rows"] = int(counts["unknown_rows"] or 0)
        result["cost_partial"] = result["cost_unknown_rows"] > 0
        result["cost_any_known"] = int(counts["known_rows"] or 0) > 0
    return result


def query_breakdown(
    conn: sqlite3.Connection,
    start: str,
    end: str,
    metric: str = "total",
    by: str = "source",
) -> dict:
    """Aggregate by source / model / device / project, sorted by value desc."""
    expr = _metric_expr(metric)
    try:
        key_expr = BREAKDOWN_KEYS[by]
    except KeyError:
        raise ValueError(
            f"unknown breakdown key {by!r}, expected one of {sorted(BREAKDOWN_KEYS)}"
        ) from None
    rows = conn.execute(
        f"SELECT {key_expr} AS key, SUM({expr}) AS value, "
        f"SUM(COALESCE({COST_EXPR}, 0.0)) AS cost, "
        f"SUM(CASE WHEN {UNKNOWN_COST_EXPR} THEN 1 ELSE 0 END) AS cost_missing, "
        f"SUM(CASE WHEN {UNKNOWN_COST_EXPR} THEN 0 ELSE 1 END) AS cost_known_rows "
        "FROM usage_events "
        "WHERE date(ts, 'localtime') BETWEEN ? AND ? "
        "GROUP BY key ORDER BY value DESC",
        (start, end),
    ).fetchall()
    total = sum(row["value"] or 0 for row in rows)
    cost_total = sum(row["cost"] or 0.0 for row in rows)
    cost_partial = any(row["cost_missing"] for row in rows)
    cost_any_known = any(row["cost_known_rows"] for row in rows)
    out_rows = []
    for row in rows:
        key = row["key"] if row["key"] is not None else "—"
        raws = _raw_values(conn, start, end, by, row["key"])
        row_partial = bool(row["cost_missing"])
        row_any_known = bool(row["cost_known_rows"])
        out_rows.append(
            {
                "key": key,
                "value": _round(row["value"], metric),
                "share": (row["value"] / total) if total else 0.0,
                "cost": round(row["cost"] or 0.0, 6),
                "cost_known": not row_partial,
                "cost_any_known": row_any_known,
                "cost_partial": row_partial,
                "cost_share": ((row["cost"] or 0.0) / cost_total) if cost_total else 0.0,
                "raw": raws,
            }
        )
    return {
        "rows": out_rows,
        "total": _round(total, metric),
        "cost_total": round(cost_total, 6),
        "cost_partial": cost_partial,
        "cost_any_known": cost_any_known,
        "metric": metric,
        "by": by,
    }


def _raw_values(
    conn: sqlite3.Connection, start: str, end: str, by: str, key
) -> list[str]:
    """Distinct model_raw / provider names behind one aggregate key."""
    if key is None:
        return []
    column = "model_raw" if by == "model" else "provider"
    key_expr = BREAKDOWN_KEYS[by]
    rows = conn.execute(
        f"SELECT DISTINCT COALESCE({column}, '') AS raw FROM usage_events "
        f"WHERE date(ts, 'localtime') BETWEEN ? AND ? AND {key_expr} IS ? "
        f"ORDER BY raw",
        (start, end, key),
    ).fetchall()
    return [row["raw"] for row in rows if row["raw"]]


def query_meta(conn: sqlite3.Connection) -> dict:
    first = conn.execute(
        "SELECT MIN(date(ts, 'localtime')) AS d FROM usage_events"
    ).fetchone()["d"]
    last = conn.execute(
        "SELECT MAX(date(ts, 'localtime')) AS d FROM usage_events"
    ).fetchone()["d"]
    last_ingest = conn.execute(
        "SELECT MAX(ingested_at) AS t FROM ingested_files"
    ).fetchone()["t"]
    devices = [
        row["device"]
        for row in conn.execute(
            "SELECT DISTINCT device FROM usage_events ORDER BY device"
        ).fetchall()
    ]
    return {
        "sources": sources_in_db(conn),
        "devices": devices,
        "first_day": first,
        "last_day": last,
        "last_ingest_at": last_ingest,
    }


def _round(value, metric: str):
    if value is None:
        return 0.0 if metric == "cost" else 0
    if metric == "cost":
        return round(float(value), 6)
    return int(value)
