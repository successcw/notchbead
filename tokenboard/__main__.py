"""Command line entry point: ``python3 -m tokenboard ingest|summary|serve``."""

from __future__ import annotations

import argparse
import datetime as _dt
import sys

from . import config, db, ingest as ingest_mod
from .sources import SOURCE_NAMES

METRICS = ("total", "io", "input", "output", "cost")
METRIC_LABELS = {
    "total": "total (input+output+cache)",
    "io": "io (input+output)",
    "input": "input",
    "output": "output",
    "cost": "cost (USD)",
}


def _fmt(value, metric: str) -> str:
    if metric == "cost":
        return f"{value:,.4f}"
    return f"{int(value):,}"


def cmd_ingest(args) -> int:
    conn = db.connect()
    try:
        before = db.event_count(conn)
        result = ingest_mod.ingest(conn=conn, device=config.device())
        after = db.event_count(conn)
    finally:
        conn.close()

    print(f"db: {config.db_path()}")
    print(f"device: {config.device()}")
    for name in SOURCE_NAMES:
        stats = result["sources"].get(name, {})
        print(
            f"{name}: {stats.get('rows', 0)} new rows, "
            f"{stats.get('changed', 0)}/{stats.get('scanned', 0)} files re-read, "
            f"{stats.get('errors', 0)} errors"
        )
    print(f"new rows: {after - before}  (rows before: {before:,}, now: {after:,})")
    return 0


MAX_DAYS = 3660  # keep --days from overflowing timedelta/date_range


def cmd_summary(args) -> int:
    metric = args.metric
    days = max(int(args.days), 1)
    if days > MAX_DAYS:
        print(f"error: --days {days} is larger than the supported {MAX_DAYS}", file=sys.stderr)
        return 2
    end = db.local_today()
    start = end - _dt.timedelta(days=days - 1)
    conn = db.connect()
    try:
        data = db.query_daily(conn, start.isoformat(), end.isoformat(), metric)
    finally:
        conn.close()

    sources = [name for name in SOURCE_NAMES if name in data["series"]]
    sources += [name for name in data["series"] if name not in sources]
    headers = ["day"] + sources + ["total"]
    rows = []
    totals = {name: 0 for name in sources}
    grand = 0
    for index, day in enumerate(data["days"]):
        values = {name: data["series"][name][index] for name in sources}
        day_total = sum(values.values())
        for name in sources:
            totals[name] += values[name]
        grand += day_total
        rows.append([day] + [_fmt(values[name], metric) for name in sources] + [
            _fmt(day_total, metric)
        ])
    rows.append(
        ["TOTAL"]
        + [_fmt(totals[name], metric) for name in sources]
        + [_fmt(grand, metric)]
    )

    widths = [max(len(str(header)), *(len(row[i]) for row in rows)) for i, header in
              enumerate(headers)]
    line = "  ".join(str(header).rjust(width) for header, width in zip(headers, widths))
    print(f"metric: {METRIC_LABELS.get(metric, metric)}   "
          f"range: {data['days'][0]} .. {data['days'][-1]}")
    print(line)
    print("  ".join("-" * width for width in widths))
    for row in rows:
        print("  ".join(str(cell).rjust(width) for cell, width in zip(row, widths)))
    if not sources:
        print("(no data yet — run: python3 -m tokenboard ingest)")
    if metric == "cost":
        # Same rule as the web API: cost_log, else pricing.json, else unknown.
        if data.get("cost_partial"):
            print(
                f"note: 部分（partial）— {data.get('cost_unknown_rows', 0)} rows in range "
                "have no known price, so the totals only cover models listed in "
                "tokenboard/pricing.json"
            )
            if not data.get("cost_any_known"):
                print("note: 当前区间没有任何已定价模型，成本全部未知（显示 0.0000）")
    return 0


def cmd_serve(args) -> int:
    from . import server

    port = args.port if args.port is not None else config.port()
    return server.serve(port)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="tokenboard")
    sub = parser.add_subparsers(dest="command", required=True)

    p_ingest = sub.add_parser("ingest", help="ingest all sources into the database")
    p_ingest.set_defaults(func=cmd_ingest)

    p_summary = sub.add_parser("summary", help="print a day x source table")
    p_summary.add_argument("--days", default=7, type=int, help="number of days (default 7)")
    p_summary.add_argument(
        "--metric", default="total", choices=METRICS, help="metric to aggregate"
    )
    p_summary.set_defaults(func=cmd_summary)

    p_serve = sub.add_parser("serve", help="run the local web server")
    p_serve.add_argument("--port", default=None, type=int, help="port (default 8787)")
    p_serve.set_defaults(func=cmd_serve)
    return parser


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
