"""CLI surface: ingest / summary / serve."""

from __future__ import annotations

import contextlib
import datetime as _dt
import io
import json
import os
import sys
import unittest
from unittest import mock

from tests.support import TempEnvTestCase
from tokenboard import config, db
from tokenboard.__main__ import main


def run_cli(argv):
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        code = main(argv)
    return code, buffer.getvalue()


class CliTests(TempEnvTestCase):
    def test_ingest_prints_per_source_counts(self):
        self.put_pi("fork_parent.jsonl", "fork_copy.jsonl")
        self.put_claude("multiline.jsonl")
        self.put_codex("fallback.jsonl")
        code, out = run_cli(["ingest"])
        self.assertEqual(code, 0)
        self.assertIn("pi: 2 new rows", out)
        self.assertIn("claude-code: 2 new rows", out)
        self.assertIn("codex: 2 new rows", out)
        self.assertIn("new rows: 6", out)
        code, out = run_cli(["ingest"])
        self.assertIn("new rows: 0", out)

    def test_summary_prints_day_by_source_table(self):
        self.put_pi("fork_parent.jsonl")
        self.put_codex("preferred.jsonl")
        self.run_ingest()
        code, out = run_cli(["summary", "--days", "3", "--metric", "io"])
        self.assertEqual(code, 0)
        self.assertIn("metric: io (input+output)", out)
        self.assertIn("day", out)
        self.assertIn("pi", out)
        self.assertIn("codex", out)
        self.assertIn("total", out)
        self.assertIn("TOTAL", out)
        # 3 day rows + TOTAL footer
        table_rows = [line for line in out.splitlines() if line.strip().startswith("20")]
        self.assertEqual(len(table_rows), 3)

    def test_summary_on_empty_db_still_renders(self):
        code, out = run_cli(["summary", "--days", "2", "--metric", "cost"])
        self.assertEqual(code, 0)
        self.assertIn("(no data yet", out)

    def test_summary_includes_rows_from_today(self):
        conn = db.connect()
        try:
            db.insert_event(
                conn,
                {
                    "id": "pi:today",
                    "source": "pi",
                    "ts": _dt.datetime.now(_dt.UTC)
                    .isoformat(timespec="milliseconds")
                    .replace("+00:00", "Z"),
                    "device": "testhost",
                    "input": 5,
                    "output": 5,
                    "cost_log": 0.5,
                },
            )
            conn.commit()
        finally:
            conn.close()
        _, out = run_cli(["summary", "--days", "1", "--metric", "io"])
        today = db.local_today().isoformat()
        today_row = [line for line in out.splitlines() if line.startswith(today)][0]
        cells = today_row.split()
        self.assertEqual(cells[1], "10")
        self.assertEqual(cells[-1], "10")
        _, out = run_cli(["summary", "--days", "1", "--metric", "cost"])
        self.assertIn("0.5000", out)

    def test_summary_cost_prices_rows_and_notes_the_partial_total(self):
        # Same rule as the web API: logged cost, else pricing.json, else unknown.
        pricing_file = self.root / "pricing.json"
        pricing_file.write_text(
            json.dumps(
                {
                    "_comment": "test table",
                    "claude-opus-5-5": {
                        "input": 4.0,
                        "output": 20.0,
                        "cache_read": 0.2,
                        "cache_write": 8.0,
                    },
                }
            ),
            encoding="utf-8",
        )
        ts = (
            _dt.datetime.now(_dt.UTC)
            .isoformat(timespec="milliseconds")
            .replace("+00:00", "Z")
        )
        conn = db.connect()
        try:
            db.insert_event(
                conn,
                {
                    "id": "claude-code:priced",
                    "source": "claude-code",
                    "ts": ts,
                    "model_raw": "claude-opus-5-5",
                    "device": "testhost",
                    "input": 1_000_000,
                    "cost_log": None,
                },
            )
            db.insert_event(
                conn,
                {
                    "id": "codex:unpriced",
                    "source": "codex",
                    "ts": ts,
                    "model_raw": "gpt-6-astra",
                    "device": "testhost",
                    "input": 5_000,
                    "cost_log": None,
                },
            )
            conn.commit()
        finally:
            conn.close()

        with mock.patch.dict(os.environ, {"TOKENBOARD_PRICING": str(pricing_file)}):
            code, out = run_cli(["summary", "--days", "1", "--metric", "cost"])
        self.assertEqual(code, 0)
        header = [line for line in out.splitlines() if line.strip().startswith("day")][0]
        columns = header.split()
        self.assertIn("claude-code", columns)
        total_row = [line for line in out.splitlines() if line.strip().startswith("TOTAL")][0].split()
        claude_index = columns.index("claude-code")
        self.assertEqual(total_row[claude_index], "4.0000")  # 1M input * $4/1M
        self.assertEqual(total_row[-1], "4.0000")  # unpriced codex adds nothing
        self.assertIn("部分", out)
        self.assertIn("pricing.json", out)

    def test_summary_cost_notes_when_nothing_in_range_is_priced(self):
        pricing_file = self.root / "pricing.json"
        pricing_file.write_text(json.dumps({}), encoding="utf-8")
        conn = db.connect()
        try:
            db.insert_event(
                conn,
                {
                    "id": "codex:unpriced-only",
                    "source": "codex",
                    "ts": _dt.datetime.now(_dt.UTC)
                    .isoformat(timespec="milliseconds")
                    .replace("+00:00", "Z"),
                    "model_raw": "gpt-6-astra",
                    "device": "testhost",
                    "input": 1_000,
                },
            )
            conn.commit()
        finally:
            conn.close()
        with mock.patch.dict(os.environ, {"TOKENBOARD_PRICING": str(pricing_file)}):
            code, out = run_cli(["summary", "--days", "1", "--metric", "cost"])
        self.assertEqual(code, 0)
        self.assertIn("部分", out)
        self.assertIn("没有任何已定价模型", out)

    def test_serve_delegates_to_the_web_server(self):
        # ``serve`` blocks forever, so assert the wiring instead of serving.
        calls = []

        def fake_serve(port, host="127.0.0.1"):
            calls.append((port, host))
            return 0

        with mock.patch("tokenboard.server.serve", fake_serve):
            code, _ = run_cli(["serve", "--port", "8799"])
        self.assertEqual(code, 0)
        self.assertEqual(calls[0], (8799, "127.0.0.1"))

        with mock.patch("tokenboard.server.serve", fake_serve):
            code, _ = run_cli(["serve"])
        self.assertEqual(code, 0)
        self.assertEqual(calls[1], (config.port(), "127.0.0.1"))

    def test_unknown_metric_is_rejected_by_argparse(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                main(["summary", "--metric", "bogus"])


if __name__ == "__main__":
    sys.exit(unittest.main())
