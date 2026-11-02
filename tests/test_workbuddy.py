"""workbuddy source: field mapping, dedupe and file discovery."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

from tests.support import FIXTURES, TempEnvTestCase
from tokenboard import db, ingest as ingest_mod
from tokenboard.sources import SOURCES, workbuddy

DEEPSEEK_TS = "2026-11-01T03:33:20.000Z"
ANTHROPIC_TS = "2026-11-01T03:35:23.456Z"


class WorkbuddyFixtureTests(TempEnvTestCase):
    def setUp(self):
        super().setUp()
        # Mirror the fixture tree into the temp workbuddy root (tool-results included).
        source_dir = FIXTURES / "workbuddy"
        for path in source_dir.rglob("*"):
            if path.is_file():
                target = self.workbuddy_root / path.relative_to(source_dir)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(path.read_bytes())

    def rows_by_id(self) -> dict:
        return {row["id"]: row for row in self.rows()}

    # -- discovery ---------------------------------------------------------
    def test_tool_results_are_not_listed(self):
        files = workbuddy.iter_files(self.workbuddy_root)
        self.assertEqual([p.name for p in files], ["no-session.jsonl", "session.jsonl"])
        self.assertFalse(any("tool-results" in str(p) for p in files))

    # -- counts ------------------------------------------------------------
    def test_ingest_counts_and_dedupe(self):
        stats = self.run_ingest()
        code = stats["sources"]["workbuddy"]
        self.assertEqual(code["scanned"], 2)  # tool-results file ignored
        self.assertEqual(code["errors"], 0)
        # 5 kept from session.jsonl (identical copy collapses) + 1 from no-session
        self.assertEqual(code["rows"], 6)
        self.assertEqual(self.row_count(), 6)
        self.assertNotIn("workbuddy:fff6:7777:777", self.rows_by_id())

    def test_identical_copy_counts_once_but_different_usage_counts_twice(self):
        self.run_ingest()
        rows = self.rows_by_id()
        # same messageId + same tokens -> one row
        self.assertEqual(len([i for i in rows if i.startswith("workbuddy:aaa1:")]), 1)
        # same messageId + different tokens -> two rows
        self.assertIn("workbuddy:ccc3:100:5", rows)
        self.assertIn("workbuddy:ccc3:100:7", rows)

    # -- exact field mapping ----------------------------------------------
    def test_deepseek_style_row(self):
        self.run_ingest()
        row = self.rows_by_id()["workbuddy:aaa1:1000:10"]
        self.assertEqual(row["source"], "workbuddy")
        self.assertEqual(row["ts"], DEEPSEEK_TS)
        self.assertEqual(row["provider"], "workbuddy")
        self.assertEqual(row["model_raw"], "deepseek-v4.1-flash")
        self.assertEqual(row["model"], "deepseek-v4.1-flash")
        # prompt_tokens includes cache reads: 1000 - 200
        self.assertEqual(row["input"], 800)
        self.assertEqual(row["output"], 10)
        self.assertEqual(row["cache_read"], 200)
        self.assertEqual(row["cache_write"], 0)
        self.assertEqual(row["reasoning"], 3)  # completion_tokens_details
        self.assertEqual(row["session_id"], "sess-wb")
        self.assertIsNone(row["cost_log"])  # credit is not USD
        # the row appeared before any cwd; project is filled from a later line
        self.assertEqual(row["project"], "/tmp/wb-proj")

    def test_anthropic_style_row_with_cache_write(self):
        self.run_ingest()
        row = self.rows_by_id()["workbuddy:bbb2:1000:20"]
        self.assertEqual(row["ts"], ANTHROPIC_TS)
        self.assertEqual(row["input"], 500)  # 1000 - 400 read - 100 write
        self.assertEqual(row["output"], 20)
        self.assertEqual(row["cache_read"], 400)
        self.assertEqual(row["cache_write"], 100)
        self.assertEqual(row["reasoning"], 7)  # completion_thinking_tokens fallback
        self.assertEqual(row["model_raw"], "claude-x")  # requestModelId fallback
        self.assertEqual(row["model"], "claude-x")
        self.assertEqual(row["project"], "/tmp/wb-proj")
        # no own sessionId on this line -> the session-meta id, never the id of
        # an unrelated earlier line ("sess-wb" belongs to row aaa1 only).
        self.assertEqual(row["session_id"], "sess-meta")

    def test_session_id_falls_back_to_file_stem(self):
        self.run_ingest()
        row = self.rows_by_id()["workbuddy:eee5:10:2"]
        self.assertEqual(row["session_id"], "no-session")
        self.assertEqual(row["project"], "/tmp/wb-other")

    def test_message_id_fallback_uses_sha1(self):
        self.run_ingest()
        rows = [i for i in self.rows_by_id() if i.startswith("workbuddy:sha1:")]
        self.assertEqual(len(rows), 1)
        self.assertRegex(rows[0], r"^workbuddy:sha1:[0-9a-f]{16}$")

    def test_skipped_lines_do_not_produce_rows(self):
        self.run_ingest()
        rows = self.rows_by_id()
        self.assertNotIn("workbuddy:ddd4:999:99", rows)  # no timestamp
        self.assertEqual(len(rows), 6)  # invalid JSON / no providerData ignored

    def test_non_finite_tokens_do_not_break_the_file(self):
        # json 1e309 parses as inf (and NaN is accepted by Python's json), and
        # both used to be a file-level failure: the neighbouring row must still land.
        path = self.workbuddy_root / "nonfinite.jsonl"
        path.write_text(
            "\n".join(
                [
                    '{"type":"message","timestamp":1793505000001,"cwd":"/tmp/wb-inf",'
                    '"providerData":{"messageId":"inf1","model":"glm-5.2",'
                    '"rawUsage":{"prompt_tokens":1e309,"completion_tokens":5}}}',
                    '{"type":"message","timestamp":1793505000001,"cwd":"/tmp/wb-inf",'
                    '"providerData":{"messageId":"nan1","model":"glm-5.2",'
                    '"rawUsage":{"prompt_tokens":NaN,"completion_tokens":3}}}',
                    '{"type":"message","timestamp":1793505000001,"cwd":"/tmp/wb-inf",'
                    '"providerData":{"messageId":"ok1","model":"glm-5.2",'
                    '"rawUsage":{"prompt_tokens":40,"completion_tokens":2}}}',
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        stats = self.run_ingest()
        self.assertEqual(stats["sources"]["workbuddy"]["errors"], 0)
        rows = self.rows_by_id()
        self.assertIn("workbuddy:ok1:40:2", rows)
        self.assertEqual(rows["workbuddy:ok1:40:2"]["input"], 40)
        # the non-finite counters collapse to 0 instead of poisoning the row
        self.assertIn("workbuddy:inf1:0:5", rows)
        self.assertEqual(rows["workbuddy:inf1:0:5"]["input"], 0)
        self.assertIn("workbuddy:nan1:0:3", rows)
        self.assertEqual(rows["workbuddy:nan1:0:3"]["input"], 0)

    def test_explicit_zero_reasoning_wins_over_the_legacy_field(self):
        path = self.workbuddy_root / "reasoning.jsonl"
        path.write_text(
            '{"type":"message","timestamp":1793505000001,"cwd":"/tmp/wb-r",'
            '"providerData":{"messageId":"r1","model":"glm-5.2",'
            '"rawUsage":{"prompt_tokens":10,"completion_tokens":4,'
            '"completion_tokens_details":{"reasoning_tokens":0},'
            '"completion_thinking_tokens":42}}}\n',
            encoding="utf-8",
        )
        self.run_ingest()
        rows = self.rows_by_id()
        self.assertIn("workbuddy:r1:10:4", rows)
        self.assertEqual(rows["workbuddy:r1:10:4"]["reasoning"], 0)

    def test_reingest_is_idempotent(self):
        self.run_ingest()
        before = self.row_count()
        stats = self.run_ingest()
        self.assertEqual(stats["sources"]["workbuddy"]["rows"], 0)
        self.assertEqual(self.row_count(), before)


class WorkbuddyUnitTests(unittest.TestCase):
    """Pure helpers: timestamp conversion and the counter mapping."""

    def test_iso_from_ms(self):
        self.assertEqual(workbuddy.iso_from_ms(1793504000000), DEEPSEEK_TS)
        self.assertEqual(workbuddy.iso_from_ms(1793504999999), "2026-11-01T03:49:59.999Z")

    def test_iso_from_ms_rejects_invalid(self):
        for value in (None, "", "1793504000000", [], {}, True, float("nan")):
            self.assertIsNone(workbuddy.iso_from_ms(value), value)

    def test_mapping_takes_the_largest_cache_read_signal(self):
        mapped = workbuddy._mapping(
            {
                "prompt_tokens": 1000,
                "completion_tokens": 5,
                "prompt_cache_hit_tokens": 100,
                "cache_read_input_tokens": 300,
                "cached_tokens": 200,
                "prompt_tokens_details": {"cached_tokens": 250},
                "cache_creation_input_tokens": 50,
                "prompt_cache_write_tokens": 20,
            }
        )
        self.assertEqual(mapped["cache_read"], 300)
        self.assertEqual(mapped["cache_write"], 50)
        self.assertEqual(mapped["input"], 1000 - 300 - 50)

    def test_mapping_treats_missing_and_non_numeric_as_zero(self):
        mapped = workbuddy._mapping(
            {"prompt_tokens": None, "completion_tokens": "abc", "prompt_tokens_details": []}
        )
        self.assertEqual(
            {k: mapped[k] for k in ("input", "output", "cache_read", "cache_write", "reasoning")},
            {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "reasoning": 0},
        )

    def test_num_rejects_non_finite_and_overlarge_values(self):
        self.assertEqual(workbuddy._num(float("inf")), 0)
        self.assertEqual(workbuddy._num(float("nan")), 0)
        self.assertEqual(workbuddy._num(1e309), 0)
        self.assertEqual(workbuddy._num(10**30), 2**63 - 1)  # clamped, not a crash
        self.assertEqual(workbuddy._num("12"), 12)
        self.assertEqual(workbuddy._num("12.5"), 0)  # not an integer counter
        self.assertEqual(workbuddy._num([]), 0)

    def test_input_never_goes_negative(self):
        mapped = workbuddy._mapping(
            {"prompt_tokens": 10, "completion_tokens": 1, "cache_read_input_tokens": 50}
        )
        self.assertEqual(mapped["input"], 0)
        self.assertEqual(mapped["cache_read"], 50)

    def test_registered_in_source_order(self):
        self.assertEqual(
            [source.NAME for source in SOURCES],
            ["pi", "claude-code", "codex", "workbuddy"],
        )


if __name__ == "__main__":
    sys.exit(unittest.main())
