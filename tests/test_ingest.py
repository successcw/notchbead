"""Ingest-level behaviour: change detection, idempotency, resilience."""

from __future__ import annotations

import os
import sys
import unittest

from tests.support import (
    TempEnvTestCase,
    codex_session_meta,
    codex_token_count,
)
from tokenboard import config, db
from tokenboard import ingest as ingest_mod

EARLY = "2026-06-29T08:00:00.000Z"
LATE = "2026-06-29T18:00:00.000Z"


class _FakeSource:
    """Minimal source whose parser yields one row and then blows up mid-file."""

    NAME = "fake"

    def __init__(self, root, good_path, bad_path):
        self._root = root
        self._good = good_path
        self._bad = bad_path

    def roots(self):
        return [self._root]

    def iter_files(self, root):
        return sorted([self._bad, self._good])

    def parse_file(self, path, device):
        if str(path) == str(self._bad):
            yield self._row("fake:partial-row", "2026-06-29T09:00:00.000Z")
            raise RuntimeError("boom midway through the file")
        yield self._row("fake:good-row", "2026-06-29T10:00:00.000Z")

    @staticmethod
    def _row(row_id, ts):
        return {
            "id": row_id,
            "source": "fake",
            "ts": ts,
            "device": "testhost",
            "input": 7,
            "output": 3,
        }


class DuplicateTimestampTests(TempEnvTestCase):
    """Resumed codex sessions re-emit token_count events with later timestamps."""

    def _write_duplicate(self, name: str, ts: str):
        return self.write_lines(
            self.codex_sessions,
            name,
            [
                codex_session_meta("sess-dup", ts=ts),
                codex_token_count(ts, 110, last={"input_tokens": 100, "output_tokens": 10}),
            ],
        )

    def test_earliest_ts_wins_when_early_file_is_read_first(self):
        self._write_duplicate("a_early.jsonl", EARLY)
        self._write_duplicate("b_late.jsonl", LATE)
        self.run_ingest()
        row = self.only_row()
        self.assertEqual(row["id"], "codex:sess-dup:tc:110")
        self.assertEqual(row["ts"], EARLY)

    def test_earliest_ts_wins_when_late_file_is_read_first(self):
        # Walk order must not decide the stored day: the late copy arrives first.
        self._write_duplicate("a_late.jsonl", LATE)
        self._write_duplicate("b_early.jsonl", EARLY)
        self.run_ingest()
        row = self.only_row()
        self.assertEqual(row["id"], "codex:sess-dup:tc:110")
        self.assertEqual(row["ts"], EARLY)

    def test_incremental_earlier_copy_repairs_ts_without_adding_a_row(self):
        self._write_duplicate("first_late.jsonl", LATE)
        self.run_ingest()
        self.assertEqual(self.only_row()["ts"], LATE)

        # A resumed rollout showing up in a later run carries the earlier copy.
        self._write_duplicate("second_early.jsonl", EARLY)
        stats = self.run_ingest()
        self.assertEqual(stats["sources"]["codex"]["rows"], 0)  # repair, not a new row
        self.assertEqual(self.row_count(), 1)
        self.assertEqual(self.only_row()["ts"], EARLY)

    def test_ts_repair_survives_a_second_ingest(self):
        self._write_duplicate("a_late.jsonl", LATE)
        self._write_duplicate("b_early.jsonl", EARLY)
        self.run_ingest()
        stats = self.run_ingest()
        self.assertEqual(stats["rows"], 0)
        self.assertEqual(self.only_row()["ts"], EARLY)

    def test_schema_upgrade_repairs_a_wrongly_stored_ts(self):
        # Simulate a database written by the old parser: late ts stored, files
        # already marked ingested. The version bump must re-parse and repair it.
        first = self._write_duplicate("a_late.jsonl", LATE)
        second = self._write_duplicate("b_early.jsonl", EARLY)
        conn = db.connect()
        try:
            db.insert_event(
                conn,
                {
                    "id": "codex:sess-dup:tc:110",
                    "source": "codex",
                    "ts": LATE,
                    "device": "testhost",
                    "input": 100,
                    "output": 10,
                },
            )
            for path in (first, second):
                state = path.stat()
                db.record_file(conn, str(path), "codex", state.st_size, state.st_mtime)
            conn.execute("PRAGMA user_version = 1")
            conn.commit()
        finally:
            conn.close()

        stats = self.run_ingest()
        self.assertEqual(stats["sources"]["codex"]["changed"], 2)  # all re-parsed
        self.assertEqual(stats["sources"]["codex"]["rows"], 0)
        self.assertEqual(self.row_count(), 1)
        self.assertEqual(self.only_row()["ts"], EARLY)


class IngestLoopTests(TempEnvTestCase):
    def test_reingest_does_not_change_row_count(self):
        self.put_pi("fork_parent.jsonl", "fork_copy.jsonl")
        self.put_claude("multiline.jsonl", "synthetic.jsonl")
        self.put_codex("preferred.jsonl", "fallback.jsonl")
        first = self.run_ingest()
        rows_after_first = self.row_count()
        self.assertEqual(rows_after_first, 2 + 2 + 2 + 2)
        self.assertEqual(first["sources"]["pi"]["rows"], 2)

        second = self.run_ingest()
        self.assertEqual(self.row_count(), rows_after_first)
        self.assertEqual(second["rows"], 0)
        for name in ("pi", "claude-code", "codex"):
            self.assertEqual(second["sources"][name]["changed"], 0, name)

    def test_touching_a_file_forces_a_reparse_without_duplicates(self):
        self.put_pi("fork_parent.jsonl")
        self.run_ingest()
        self.assertEqual(self.row_count(), 1)
        path = self.pi_root / "fork_parent.jsonl"
        os.utime(path, (path.stat().st_atime, path.stat().st_mtime + 10))
        stats = self.run_ingest()
        self.assertEqual(stats["sources"]["pi"]["changed"], 1)
        self.assertEqual(stats["sources"]["pi"]["rows"], 0)
        self.assertEqual(self.row_count(), 1)

    def test_broken_file_does_not_stop_the_run(self):
        self.put_pi("fork_parent.jsonl")
        broken = self.pi_root / "broken.jsonl"
        broken.write_text('{"type":"session","id":"s","cwd":"/tmp"}\n{not json\n',
                          encoding="utf-8")
        stats = self.run_ingest()
        self.assertEqual(stats["sources"]["pi"]["rows"], 1)
        self.assertEqual(self.row_count(), 1)

    def test_parser_exception_rolls_back_partial_rows_and_skips_file(self):
        # Invalid JSON is legitimately skipped by parsers, so exercise the real
        # failure path: a parser that yields a row and then raises.
        work = self.root / "fake-logs"
        bad = work / "a_bad.jsonl"
        good = work / "b_good.jsonl"
        work.mkdir(parents=True, exist_ok=True)
        bad.write_text("{}\n", encoding="utf-8")
        good.write_text("{}\n", encoding="utf-8")
        source = _FakeSource(work, good, bad)

        messages = []
        stats = ingest_mod.ingest(
            device="testhost", sources=[source], log=messages.append
        )

        fake = stats["sources"]["fake"]
        self.assertEqual(fake["errors"], 1)
        self.assertEqual(fake["rows"], 1)  # only the good file's row
        self.assertEqual([row["id"] for row in self.rows()], ["fake:good-row"])
        paths = self.ingested_paths()
        self.assertNotIn(str(bad), paths)
        self.assertIn(str(good), paths)
        log_text = "\n".join(messages)
        self.assertIn("failed to parse", log_text)
        self.assertIn(str(bad), log_text)
        self.assertIn("boom midway through the file", log_text)

    def test_all_zero_rows_are_skipped(self):
        self.write_pi(
            "zero.jsonl",
            [
                '{"type":"session","version":3,"id":"sess-zero","timestamp":'
                '"2026-11-01T07:00:00.000Z","cwd":"/tmp/proj-zero"}',
                '{"type":"message","id":"eee55555","parentId":null,"timestamp":'
                '"2026-11-01T07:00:01.000Z","message":{"role":"assistant",'
                '"provider":"deepseek","model":"deepseek-v3","usage":'
                '{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0}}}',
            ],
        )
        self.run_ingest()
        self.assertEqual(self.row_count(), 0)

    def test_ingested_files_table_records_each_file(self):
        self.put_pi("fork_parent.jsonl", "fork_copy.jsonl")
        self.run_ingest()
        conn = db.connect()
        try:
            files = conn.execute(
                "SELECT path, source, size FROM ingested_files ORDER BY path"
            ).fetchall()
        finally:
            conn.close()
        self.assertEqual(len(files), 2)
        self.assertTrue(all(row["source"] == "pi" for row in files))
        self.assertTrue(all(row["size"] > 0 for row in files))


class ConfigTests(TempEnvTestCase):
    def test_env_overrides_are_used(self):
        self.assertEqual(config.db_path(), self.db_path)
        self.assertEqual(config.pi_dir(), self.pi_root)
        self.assertEqual(config.claude_dir(), self.claude_root)
        self.assertEqual(config.codex_dir(), self.codex_root)
        self.assertEqual(config.codex_sessions_dir(), self.codex_sessions)
        self.assertEqual(config.codex_archived_dir(), self.codex_archived)
        self.assertEqual(config.device(), "testhost")

    def test_missing_roots_are_empty(self):
        missing = self.root / "nope"
        self.assertEqual(config._env_path("TOKENBOARD_PI_DIR", missing), self.pi_root)


if __name__ == "__main__":
    sys.exit(unittest.main())
