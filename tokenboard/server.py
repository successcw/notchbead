"""Local HTTP server: JSON API, static UI and a periodic ingest thread.

Binds to 127.0.0.1 only. Every request gets its own SQLite connection (WAL mode)
so the background ingest never blocks a reader for long. Cost figures use
``pricing.json`` through :mod:`tokenboard.pricing`, which means a total can be
*partial* when some rows belong to models without a listed price.
"""

from __future__ import annotations

import datetime as _dt
import json
import mimetypes
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from . import config, db, pricing
from . import ingest as ingest_mod

STATIC_DIR = Path(__file__).with_name("static")
INDEX_FILE = "index.html"
METRICS = tuple(db.METRIC_SQL)
BREAKDOWN_KEYS = tuple(db.BREAKDOWN_KEYS)
DEFAULT_DAYS = 30
# Guard against absurd ranges: day_range() builds one entry per day, so a range
# like 0001-01-01..9999-12-31 must be rejected instead of exhausting memory.
MAX_RANGE_DAYS = 3660  # ~10 years
DATE_RE = re.compile(r"\A\d{4}-\d{2}-\d{2}\Z")
INGEST_INTERVAL = 300

# Cost is a Python UDF (cost_log, else pricing.json, else NULL) registered by
# db.connect(), so the API and the CLI cannot drift; other metrics reuse
# db.METRIC_SQL.
COST_EXPR = db.COST_EXPR
UNKNOWN_COST_EXPR = db.UNKNOWN_COST_EXPR


def metric_expr(metric: str) -> str:
    if metric == "cost":
        return f"COALESCE({COST_EXPR}, 0.0)"
    return db.METRIC_SQL[metric]


def open_conn() -> "db.sqlite3.Connection":
    """A fresh connection per request: WAL + a busy timeout for ingest overlap.

    ``db.connect()`` also registers the ``row_cost`` UDF with a freshly loaded
    price table, so the API and the CLI price rows identically.
    """
    conn = db.connect()
    conn.execute("PRAGMA busy_timeout = 5000")
    return conn


def parse_date(value: str, field: str) -> _dt.date:
    """Parse a strict ``YYYY-MM-DD`` date (rejects ``20261101``, ``2026-W44-1``…)."""
    if not DATE_RE.match(value):
        raise ValueError(f"{field} must be YYYY-MM-DD, got {value!r}")
    try:
        return _dt.date.fromisoformat(value)
    except ValueError:
        raise ValueError(f"{field} is not a valid calendar date: {value!r}") from None


def _round_value(value, metric: str):
    if metric == "cost":
        return round(float(value or 0.0), 6)
    return int(value or 0)


def day_list(start: str, end: str) -> list[str]:
    """Inclusive ``YYYY-MM-DD`` list; safe at the calendar edges.

    ``db.day_range`` steps past ``date.max`` for ``9999-12-31`` (OverflowError),
    so the server builds its own list and never increments beyond the end date.
    """
    first = _dt.date.fromisoformat(start)
    last = _dt.date.fromisoformat(end)
    span = (last - first).days + 1
    if span <= 0:
        return []
    return [(first + _dt.timedelta(days=offset)).isoformat() for offset in range(span)]


def query_daily(conn, start: str, end: str, metric: str) -> dict:
    """``{days:[...], series:{source:[value per day]}}`` with zero-filled days."""
    rows = conn.execute(
        f"SELECT date(ts, 'localtime') AS day, source, SUM({metric_expr(metric)}) AS value "
        "FROM usage_events WHERE date(ts, 'localtime') BETWEEN ? AND ? "
        "GROUP BY day, source ORDER BY day",
        (start, end),
    ).fetchall()
    days = day_list(start, end)
    sources = sorted({row["source"] for row in rows}) or db.sources_in_db(conn)
    series = {source: [0.0 if metric == "cost" else 0] * len(days) for source in sources}
    index = {day: i for i, day in enumerate(days)}
    for row in rows:
        series[row["source"]][index[row["day"]]] = _round_value(row["value"], metric)
    return {"days": days, "series": series}


def query_breakdown(conn, start: str, end: str, metric: str, by: str) -> dict:
    """Aggregate by source / model / device / project, value descending."""
    key_expr = db.BREAKDOWN_KEYS[by]
    raw_column = {"model": "model_raw", "source": "provider"}.get(by)
    rows = conn.execute(
        f"SELECT {key_expr} AS key, SUM({metric_expr(metric)}) AS value, "
        f"SUM(COALESCE({COST_EXPR}, 0.0)) AS cost, "
        f"SUM(CASE WHEN {UNKNOWN_COST_EXPR} THEN 1 ELSE 0 END) AS cost_missing, "
        f"SUM(CASE WHEN {UNKNOWN_COST_EXPR} THEN 0 ELSE 1 END) AS cost_known_rows "
        "FROM usage_events WHERE date(ts, 'localtime') BETWEEN ? AND ? "
        "GROUP BY key ORDER BY value DESC, key ASC",
        (start, end),
    ).fetchall()

    # Raw names come back from their own DISTINCT query: GROUP_CONCAT would make
    # a model_raw containing a comma indistinguishable from two separate names.
    raws_by_key: dict = {}
    if raw_column:
        for raw_row in conn.execute(
            f"SELECT {key_expr} AS key, {raw_column} AS raw FROM usage_events "
            f"WHERE date(ts, 'localtime') BETWEEN ? AND ? "
            f"AND {raw_column} IS NOT NULL AND {raw_column} <> '' "
            f"GROUP BY key, raw",
            (start, end),
        ).fetchall():
            raws_by_key.setdefault(raw_row["key"], set()).add(raw_row["raw"])

    total = sum(row["value"] or 0 for row in rows)
    cost_total = sum(row["cost"] or 0.0 for row in rows)
    cost_partial = any(row["cost_missing"] for row in rows)
    cost_any_known = any(row["cost_known_rows"] for row in rows)
    out = []
    for row in rows:
        key = row["key"] if row["key"] is not None else "—"
        raws = sorted(raws_by_key.get(row["key"], ()))
        value = row["value"] or 0
        cost_value = row["cost"] or 0.0
        row_partial = bool(row["cost_missing"])
        row_any_known = bool(row["cost_known_rows"])
        out.append(
            {
                "key": key,
                "value": _round_value(value, metric),
                "share": (value / total) if total else 0.0,
                "cost": round(cost_value, 6),
                # cost_known is kept for older clients; the UI branches on
                # cost_any_known so a mixed group still shows its subtotal.
                "cost_known": not row_partial,
                "cost_any_known": row_any_known,
                "cost_partial": row_partial,
                "cost_share": (cost_value / cost_total) if cost_total else 0.0,
                "raw": raws,
            }
        )
    return {
        "rows": out,
        "total": _round_value(total, metric),
        "cost_total": round(cost_total, 6),
        "cost_partial": cost_partial,
        "cost_any_known": cost_any_known,
    }


class TokenboardServer(ThreadingHTTPServer):
    """Threaded server holding the ingest lock, the schedule and pricing state."""

    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, handler_class, *, ingest_interval=INGEST_INTERVAL):
        self.ingest_lock = threading.Lock()
        # float(): keep sub-second intervals usable (tests) without int() truncation
        self.ingest_interval = float(ingest_interval)
        self.last_ingest_at: str | None = None
        self.last_result: dict | None = None
        self._stop = threading.Event()
        self._worker: threading.Thread | None = None
        super().__init__(address, handler_class)

    # -- ingest ------------------------------------------------------------
    def run_ingest(self) -> dict:
        """Ingest now, serialized against the background thread."""
        with self.ingest_lock:
            conn = open_conn()
            try:
                result = ingest_mod.ingest(
                    conn=conn,
                    device=config.device(),
                    log=lambda message: print(f"[ingest] {message}", flush=True),
                )
            finally:
                conn.close()
            self.last_ingest_at = _dt.datetime.now(_dt.UTC).isoformat(timespec="seconds")
            result["ingested_at"] = self.last_ingest_at
            self.last_result = result
            return result

    def start_background_ingest(self) -> None:
        if self.ingest_interval <= 0 or self._worker is not None:
            return
        self._worker = threading.Thread(
            target=self._ingest_loop, name="tokenboard-ingest", daemon=True
        )
        self._worker.start()

    def _ingest_loop(self) -> None:
        while not self._stop.wait(self.ingest_interval):
            try:
                self.run_ingest()
            except Exception as exc:  # the schedule must survive one bad run
                print(f"[ingest] failed: {exc}", flush=True)

    # -- lifecycle ---------------------------------------------------------
    def stop(self) -> None:
        self._stop.set()
        if self._worker is not None:
            self._worker.join(timeout=5)
            self._worker = None

    def server_close(self) -> None:
        self.stop()
        super().server_close()


class TokenboardHandler(BaseHTTPRequestHandler):
    server_version = "tokenboard/0.2"
    protocol_version = "HTTP/1.1"

    # -- plumbing ----------------------------------------------------------
    def log_message(self, fmt, *args):  # keep the console readable
        pass

    def _send(self, status: int, body: bytes, content_type: str, extra=None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, payload, status: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self._send(status, body, "application/json; charset=utf-8")

    def _error(self, status: int, message: str) -> None:
        self._json({"error": message}, status=status)

    def _params(self) -> dict:
        query = parse_qs(urlparse(self.path).query)
        return {key: values[-1] for key, values in query.items() if values}

    # -- routing -----------------------------------------------------------
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = urlparse(self.path).path
        try:
            if path == "/api/meta":
                return self._api_meta()
            if path == "/api/daily":
                return self._api_daily()
            if path == "/api/breakdown":
                return self._api_breakdown()
            if path == "/api/ingest":
                return self._error(405, "use POST /api/ingest")
            if path in ("/", "/index.html"):
                return self._serve_static(INDEX_FILE, cache=False)
            if path.startswith("/static/"):
                return self._serve_static(path[len("/static/"):])
            return self._error(404, f"not found: {path}")
        except BrokenPipeError:
            return None
        except Exception as exc:  # never kill the request thread silently
            return self._error(500, f"{type(exc).__name__}: {exc}")

    def do_POST(self):
        path = urlparse(self.path).path
        try:
            if path != "/api/ingest":
                return self._error(404, f"not found: {path}")
            if self.headers.get("Content-Length"):
                self.rfile.read(int(self.headers["Content-Length"]))
            result = self.server.run_ingest()
            return self._json(
                {
                    "sources": result["sources"],
                    "rows": result["rows"],
                    "scanned": result["scanned"],
                    "changed": result["changed"],
                    "errors": result["errors"],
                    "total_rows": result["total_rows"],
                    "ingested_at": result["ingested_at"],
                }
            )
        except BrokenPipeError:
            return None
        except Exception as exc:
            return self._error(500, f"{type(exc).__name__}: {exc}")

    # -- handlers ----------------------------------------------------------
    def _range(self, params: dict) -> tuple[str, str]:
        end_text = params.get("end") or db.local_today().isoformat()
        end = parse_date(end_text, "end")
        if "start" in params:
            start = parse_date(params["start"], "start")
        else:
            try:
                start = end - _dt.timedelta(days=DEFAULT_DAYS - 1)
            except (OverflowError, ValueError):
                raise ValueError(
                    f"end {end_text!r} leaves no room for the default {DEFAULT_DAYS}-day range"
                ) from None
        if start > end:
            raise ValueError(f"start {start.isoformat()} is after end {end.isoformat()}")
        span = (end - start).days + 1
        if span > MAX_RANGE_DAYS:
            raise ValueError(
                f"range too large: {span} days (max {MAX_RANGE_DAYS}); pass a start close to end"
            )
        return start.isoformat(), end.isoformat()

    def _metric(self, params: dict) -> str:
        metric = params.get("metric") or "total"
        if metric not in METRICS:
            raise ValueError(f"unknown metric {metric!r}, expected one of {list(METRICS)}")
        return metric

    def _api_meta(self):
        conn = open_conn()
        try:
            meta = db.query_meta(conn)
        finally:
            conn.close()
        server = self.server
        meta["last_ingest_at"] = (
            server.last_ingest_at or meta.get("last_ingest_at") or None
        )
        self._json(meta)

    def _api_daily(self):
        params = self._params()
        try:
            start, end = self._range(params)
            metric = self._metric(params)
        except (ValueError, OverflowError) as exc:
            return self._error(400, str(exc))
        conn = open_conn()
        try:
            payload = query_daily(conn, start, end, metric)
        finally:
            conn.close()
        self._json(payload)

    def _api_breakdown(self):
        params = self._params()
        by = params.get("by") or "source"
        try:
            start, end = self._range(params)
            metric = self._metric(params)
            if by not in BREAKDOWN_KEYS:
                raise ValueError(
                    f"unknown by {by!r}, expected one of {list(BREAKDOWN_KEYS)}"
                )
        except (ValueError, OverflowError) as exc:
            return self._error(400, str(exc))
        conn = open_conn()
        try:
            payload = query_breakdown(conn, start, end, metric, by)
        finally:
            conn.close()
        self._json(payload)

    # -- static files ------------------------------------------------------
    def _serve_static(self, name: str, cache: bool = True):
        base = STATIC_DIR.resolve()
        target = (base / name).resolve()
        if base != target and base not in target.parents:
            return self._error(403, "forbidden")
        if not target.is_file():
            return self._error(404, f"not found: {name}")
        body = target.read_bytes()
        content_type = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        if content_type.startswith("text/") or content_type in (
            "application/javascript",
            "application/json",
        ):
            content_type += "; charset=utf-8"
        extra = {"Cache-Control": "max-age=3600"} if cache else None
        self._send(200, body, content_type, extra=extra)


def make_server(
    host: str = "127.0.0.1",
    port: int | None = None,
    *,
    ingest_interval: int = INGEST_INTERVAL,
    run_ingest: bool = True,
) -> TokenboardServer:
    """Create a server bound to 127.0.0.1 (port 0 picks a free port)."""
    if host != "127.0.0.1":
        raise ValueError("tokenboard only listens on 127.0.0.1")
    server = TokenboardServer(
        (host, config.port() if port is None else port),
        TokenboardHandler,
        ingest_interval=ingest_interval,
    )
    conn = db.connect()
    try:
        conn.execute("PRAGMA journal_mode = WAL")
        conn.execute("PRAGMA synchronous = NORMAL")
        conn.commit()
    finally:
        conn.close()
    if run_ingest:
        # A failing first ingest must not abort startup or kill the schedule:
        # keep serving the existing database and let the worker retry.
        try:
            server.run_ingest()
        except Exception as exc:
            print(
                f"[ingest] initial ingest failed, serving existing data: "
                f"{type(exc).__name__}: {exc}",
                flush=True,
            )
        server.start_background_ingest()
    return server


def serve(port: int | None = None, host: str = "127.0.0.1") -> int:
    """Run until interrupted."""
    server = make_server(host, port)
    host, actual_port = server.server_address[:2]
    print(
        f"tokenboard listening on http://{host}:{actual_port}/  "
        f"(db: {config.db_path()}, device: {config.device()})",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("stopping", flush=True)
    finally:
        server.server_close()
    return 0
