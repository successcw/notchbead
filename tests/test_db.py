"""db.py: schema, insert rules, metric expressions and query shapes."""

from __future__ import annotations

import datetime as _dt
import json
import os
import sys
import unittest
from unittest import mock

from tests.support import TempEnvTestCase
from tokenboard import db


class NormalizeModelTests(unittest.TestCase):
    def test_takes_part_after_last_slash_and_lowercases(self):
        self.assertEqual(db.normalize_model("openai/gpt-5/DeepSeek-V3"), "deepseek-v3")
        self.assertEqual(db.normalize_model("  Claude-Opus-5-5  "), "claude-opus-5-5")
        self.assertEqual(db.normalize_model("gpt-6-astra"), "gpt-6-astra")

    def test_blank_values(self):
        self.assertIsNone(db.normalize_model(None))
        self.assertIsNone(db.normalize_model(""))
        self.assertIsNone(db.normalize_model("   "))


class SchemaTests(TempEnvTestCase):
    def test_schema_tables_and_index_exist(self):
        conn = db.connect()
        try:
            tables = {
                row["name"]
                for row in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'"
                )
            }
            indexes = {
                row["name"]
                for row in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type='index'"
                )
            }
            columns = [
                row["name"] for row in conn.execute("PRAGMA table_info(usage_events)")
            ]
        finally:
            conn.close()
        self.assertIn("usage_events", tables)
        self.assertIn("ingested_files", tables)
        self.assertIn("idx_usage_ts", indexes)
        self.assertEqual(
            columns,
            [
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
            ],
        )

    def test_db_file_is_created_under_temp_env(self):
        db.connect().close()
        self.assertTrue(self.db_path.exists())

    def test_insert_is_idempotent_and_skips_empty_rows(self):
        conn = db.connect()
        try:
            base = {
                "id": "pi:1",
                "source": "pi",
                "ts": "2026-11-01T00:00:00.000Z",
                "model_raw": "openai/gpt-5/DeepSeek-V3",
                "device": "testhost",
                "input": 10,
                "output": 1,
            }
            self.assertTrue(db.insert_event(conn, base))
            self.assertFalse(db.insert_event(conn, base))
            self.assertFalse(
                db.insert_event(conn, {**base, "id": "pi:2", "input": 0, "output": 0})
            )
            conn.commit()
            self.assertEqual(db.event_count(conn), 1)
            row = conn.execute("SELECT * FROM usage_events").fetchone()
        finally:
            conn.close()
        self.assertEqual(row["model"], "deepseek-v3")  # normalized on insert
        self.assertEqual(row["model_raw"], "openai/gpt-5/DeepSeek-V3")

    def test_duplicate_id_keeps_earliest_ts_and_is_not_a_new_row(self):
        conn = db.connect()
        try:
            base = {
                "id": "codex:sess:tc:110",
                "source": "codex",
                "device": "testhost",
                "input": 5,
            }
            self.assertTrue(db.insert_event(conn, {**base, "ts": "2026-06-29T18:00:00.000Z"}))
            before = db.event_count(conn)
            # A later duplicate must neither add a row nor move the ts forward.
            self.assertFalse(
                db.insert_event(conn, {**base, "ts": "2026-06-29T20:00:00.000Z"})
            )
            self.assertEqual(db.event_count(conn), before)
            self.assertEqual(
                conn.execute("SELECT ts FROM usage_events").fetchone()["ts"],
                "2026-06-29T18:00:00.000Z",
            )
            # An earlier duplicate rewrites ts, still without adding a row.
            self.assertFalse(
                db.insert_event(conn, {**base, "ts": "2026-06-29T08:00:00.000Z"})
            )
            self.assertEqual(db.event_count(conn), before)
            self.assertEqual(
                conn.execute("SELECT ts FROM usage_events").fetchone()["ts"],
                "2026-06-29T08:00:00.000Z",
            )
            conn.commit()
        finally:
            conn.close()

    def test_schema_version_bump_invalidates_file_markers_only(self):
        conn = db.connect()
        try:
            size = 10
            db.insert_event(
                conn,
                {
                    "id": "pi:keep-me",
                    "source": "pi",
                    "ts": "2026-06-29T08:00:00.000Z",
                    "device": "testhost",
                    "input": 3,
                },
            )
            db.record_file(conn, "/tmp/log.jsonl", "pi", size, 123.0)
            conn.execute("PRAGMA user_version = 1")  # simulate an older data layer
            conn.commit()
        finally:
            conn.close()

        conn = db.connect()  # upgrade runs on connect
        try:
            # History is preserved, only the change markers are invalidated so
            # that every file is re-parsed once.
            self.assertEqual(db.event_count(conn), 1)
            self.assertEqual(db.file_state(conn, "/tmp/log.jsonl"), (-1, -1))
            self.assertNotEqual(db.file_state(conn, "/tmp/log.jsonl"), (size, 123.0))
            self.assertEqual(
                int(conn.execute("PRAGMA user_version").fetchone()[0]),
                db.SCHEMA_VERSION,
            )
            paths = {row["path"] for row in conn.execute("SELECT path FROM ingested_files")}
            self.assertEqual(paths, {"/tmp/log.jsonl"})  # markers are kept, not deleted
        finally:
            conn.close()


class QueryTests(TempEnvTestCase):
    def setUp(self):
        super().setUp()
        self.put_pi("fork_parent.jsonl")
        self.put_codex("preferred.jsonl")
        self.run_ingest()
        self.conn = db.connect()
        self.addCleanup(self.conn.close)

    def test_daily_series_has_every_day_and_every_source(self):
        data = db.query_daily(self.conn, "2026-10-31", "2026-11-02", "io")
        self.assertEqual(data["days"], ["2026-10-31", "2026-11-01", "2026-11-02"])
        self.assertEqual(sorted(data["series"]), ["codex", "pi"])
        for source in data["series"]:
            self.assertEqual(len(data["series"][source]), 3)
        self.assertEqual(data["series"]["pi"][0], 0)
        self.assertEqual(sum(data["series"]["pi"]), 110)  # 100 input + 10 output
        self.assertEqual(
            sum(data["series"]["codex"]), (24704 - 21632 + 270) + (31494 - 24832 + 109)
        )

    def test_total_metric_includes_cache(self):
        data = db.query_daily(self.conn, "2026-11-01", "2026-11-01", "total")
        self.assertEqual(
            data["series"]["pi"][0], 100 + 10 + 5 + 1
        )
        self.assertEqual(
            data["series"]["codex"][0],
            (24704 - 21632) + 270 + 21632 + 0 + (31494 - 24832) + 109 + 24832 + 128,
        )

    def test_unknown_metric_is_rejected(self):
        with self.assertRaises(ValueError):
            db.query_daily(self.conn, "2026-11-01", "2026-11-01", "bogus")

    def test_breakdown_by_model_and_source(self):
        by_model = db.query_breakdown(self.conn, "2026-11-01", "2026-11-01", "io", "model")
        keys = [row["key"] for row in by_model["rows"]]
        self.assertEqual(keys, ["gpt-6-mini", "gpt-6-astra", "deepseek-v3"])
        self.assertAlmostEqual(sum(row["share"] for row in by_model["rows"]), 1.0, places=6)
        self.assertEqual(by_model["total"], 110 + 3072 + 270 + 6662 + 109)
        # pi records its own cost, codex rows do not -> partial total.
        self.assertTrue(by_model["cost_partial"])

        by_source = db.query_breakdown(self.conn, "2026-11-01", "2026-11-01", "io", "source")
        self.assertEqual([row["key"] for row in by_source["rows"]], ["codex", "pi"])
        self.assertEqual(by_source["rows"][1]["raw"], ["deepseek"])

        pi_model = [row for row in by_model["rows"] if row["key"] == "deepseek-v3"][0]
        self.assertEqual(pi_model["raw"], ["openai/gpt-5/DeepSeek-V3"])

    def test_meta_reports_sources_and_days(self):
        meta = db.query_meta(self.conn)
        self.assertEqual(meta["sources"], ["codex", "pi"])
        self.assertEqual(meta["devices"], ["testhost"])
        self.assertEqual(meta["first_day"], "2026-11-01")
        self.assertEqual(meta["last_day"], "2026-11-01")
        self.assertIsNotNone(meta["last_ingest_at"])

    def test_day_range_is_inclusive(self):
        self.assertEqual(
            db.day_range("2026-10-30", "2026-11-02"),
            ["2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02"],
        )



class BreakdownCostRuleTests(TempEnvTestCase):
    """``db.query_breakdown(metric="cost")`` must use the shared pricing rule.

    Regression: it used to sum only ``cost_log``, so priced claude-code rows
    (which never log a cost) came back as 0 instead of being estimated.
    """

    def test_priced_row_without_logged_cost_is_estimated(self):
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
        today = db.local_today().isoformat()
        ts = (
            _dt.datetime.now(_dt.UTC)
            .isoformat(timespec="milliseconds")
            .replace("+00:00", "Z")
        )
        with mock.patch.dict(os.environ, {"TOKENBOARD_PRICING": str(pricing_file)}):
            conn = db.connect()  # registers row_cost with this price table
            try:
                self.assertTrue(
                    db.insert_event(
                        conn,
                        {
                            "id": "claude-code:priced",
                            "source": "claude-code",
                            "ts": ts,
                            "model_raw": "claude-opus-5-5",
                            "device": "testhost",
                            "input": 1_000_000,
                            "output": 0,
                            "cost_log": None,
                        },
                    )
                )
                conn.commit()
                payload = db.query_breakdown(conn, today, today, "cost", "model")
            finally:
                conn.close()

        row = payload["rows"][0]
        self.assertEqual(row["key"], "claude-opus-5-5")
        self.assertAlmostEqual(row["value"], 4.0, places=6)  # 1M input * $4/1M
        self.assertAlmostEqual(row["cost"], 4.0, places=6)
        self.assertAlmostEqual(payload["cost_total"], 4.0, places=6)
        self.assertFalse(payload["cost_partial"])
        self.assertTrue(payload["cost_any_known"])
        self.assertTrue(row["cost_any_known"])
        self.assertFalse(row["cost_partial"])
        self.assertAlmostEqual(row["cost_share"], 1.0, places=6)

    def test_unpriced_row_is_flagged_unknown(self):
        pricing_file = self.root / "pricing.json"
        pricing_file.write_text(json.dumps({}), encoding="utf-8")
        today = db.local_today().isoformat()
        ts = (
            _dt.datetime.now(_dt.UTC)
            .isoformat(timespec="milliseconds")
            .replace("+00:00", "Z")
        )
        with mock.patch.dict(os.environ, {"TOKENBOARD_PRICING": str(pricing_file)}):
            conn = db.connect()
            try:
                db.insert_event(
                    conn,
                    {
                        "id": "codex:unpriced",
                        "source": "codex",
                        "ts": ts,
                        "model_raw": "gpt-6-astra",
                        "device": "testhost",
                        "input": 1_000,
                        "cost_log": None,
                    },
                )
                conn.commit()
                payload = db.query_breakdown(conn, today, today, "cost", "model")
            finally:
                conn.close()

        row = payload["rows"][0]
        self.assertEqual(row["cost"], 0)
        self.assertTrue(payload["cost_partial"])
        self.assertFalse(payload["cost_any_known"])
        self.assertFalse(row["cost_any_known"])


if __name__ == "__main__":
    sys.exit(unittest.main())
