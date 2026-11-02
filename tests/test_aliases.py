"""Model aliases: query-time merge in the 模型 breakdown."""

from __future__ import annotations

import datetime as _dt
import json
import os
import sys
import time
import unittest
from unittest import mock

from tests.support import TempEnvTestCase
from tokenboard import aliases, db

ALIASES = {
    "_comment": "comment keys are ignored",
    "deepseek-flash": "deepseek-v4.1-flash:1017",
    "deepseek-v4.1-flash": "deepseek-v4.1-flash:1017",
}


class AliasLoaderTests(unittest.TestCase):
    def setUp(self):
        import tempfile

        from pathlib import Path

        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.path = Path(self._tmp.name) / "aliases.json"
        self.path.write_text(json.dumps(ALIASES), encoding="utf-8")
        self.table = aliases.load_aliases(self.path, force=True)

    def test_comment_keys_are_ignored(self):
        self.assertEqual(
            self.table,
            {
                "deepseek-flash": "deepseek-v4.1-flash:1017",
                "deepseek-v4.1-flash": "deepseek-v4.1-flash:1017",
            },
        )

    def test_lookup_returns_name_when_unaliased(self):
        self.assertEqual(aliases.alias_for("deepseek-flash", self.table), "deepseek-v4.1-flash:1017")
        self.assertEqual(aliases.alias_for("glm-5.2", self.table), "glm-5.2")
        self.assertIsNone(aliases.alias_for(None, self.table))

    def test_keys_and_values_are_lowercased_and_trimmed(self):
        self.path.write_text(
            json.dumps({"  DeepSeek-Flash ": "  DS-V4 "}), encoding="utf-8"
        )
        table = aliases.load_aliases(self.path, force=True)
        self.assertEqual(table, {"deepseek-flash": "ds-v4"})

    def test_missing_or_invalid_file_means_no_aliases(self):
        from pathlib import Path

        missing = Path(self._tmp.name) / "nope.json"
        self.assertEqual(aliases.load_aliases(missing, force=True), {})
        broken = Path(self._tmp.name) / "broken.json"
        broken.write_text("{not json", encoding="utf-8")
        self.assertEqual(aliases.load_aliases(broken, force=True), {})

    def test_table_is_reloaded_when_the_file_changes(self):
        first = aliases.load_aliases(self.path, force=True)
        self.assertIn("deepseek-flash", first)
        time.sleep(0.01)
        self.path.write_text(json.dumps({"deepseek-flash": "renamed"}), encoding="utf-8")
        second = aliases.load_aliases(self.path)
        self.assertEqual(second, {"deepseek-flash": "renamed"})


class AliasBreakdownTests(TempEnvTestCase):
    """The 模型 breakdown merges aliased names; raw names stay visible."""

    def _seed(self):
        conn = db.connect()
        ts = (
            _dt.datetime.now(_dt.UTC)
            .isoformat(timespec="milliseconds")
            .replace("+00:00", "Z")
        )
        for row_id, model_raw, tokens in (
            ("pi:1", "deepseek-flash", 10),
            ("pi:2", "deepseek-v4.1-flash", 20),
            ("pi:3", "deepseek-v4.1-flash:1017", 30),
            ("pi:4", "glm-5.2", 5),
        ):
            db.insert_event(
                conn,
                {
                    "id": row_id,
                    "source": "pi",
                    "ts": ts,
                    "model_raw": model_raw,
                    "device": "testhost",
                    "input": tokens,
                    "output": 0,
                },
            )
        conn.commit()
        return conn

    def _breakdown(self, conn):
        today = db.local_today().isoformat()
        return db.query_breakdown(conn, today, today, "io", "model")

    def test_two_raw_names_merge_into_one_key(self):
        self.aliases_file.write_text(json.dumps(ALIASES), encoding="utf-8")
        conn = self._seed()
        try:
            payload = self._breakdown(conn)
        finally:
            conn.close()
        rows = {row["key"]: row for row in payload["rows"]}
        self.assertIn("deepseek-v4.1-flash:1017", rows)
        self.assertNotIn("deepseek-flash", rows)
        merged = rows["deepseek-v4.1-flash:1017"]
        self.assertEqual(merged["value"], 10 + 20 + 30)
        # hover shows every raw name behind the merged key
        self.assertEqual(
            merged["raw"],
            ["deepseek-flash", "deepseek-v4.1-flash", "deepseek-v4.1-flash:1017"],
        )
        self.assertIn("glm-5.2", rows)  # unaliased models stay separate

    def test_missing_alias_file_means_no_merge(self):
        os.environ["TOKENBOARD_ALIASES"] = str(self.root / "does-not-exist.json")
        conn = self._seed()
        try:
            payload = self._breakdown(conn)
        finally:
            conn.close()
        keys = {row["key"] for row in payload["rows"]}
        self.assertEqual(
            keys, {"deepseek-flash", "deepseek-v4.1-flash", "deepseek-v4.1-flash:1017", "glm-5.2"}
        )

    def test_edited_alias_file_applies_without_reconnect(self):
        self.aliases_file.write_text("{}", encoding="utf-8")
        conn = self._seed()
        try:
            before = {row["key"] for row in self._breakdown(conn)["rows"]}
            self.assertIn("deepseek-flash", before)

            time.sleep(0.01)
            self.aliases_file.write_text(json.dumps(ALIASES), encoding="utf-8")
            after = {row["key"] for row in self._breakdown(conn)["rows"]}
        finally:
            conn.close()
        self.assertIn("deepseek-v4.1-flash:1017", after)
        self.assertNotIn("deepseek-flash", after)

    def test_one_snapshot_per_breakdown(self):
        # A file change *during* a breakdown must not split one key into two:
        # the aggregate and the raw lookups share the snapshot taken at the start.
        conn = self._seed()
        calls = {"n": 0}
        first = {"deepseek-flash": "merged-ds", "deepseek-v4.1-flash": "merged-ds"}

        def flaky_load(path=None, force=False):
            calls["n"] += 1
            return first if calls["n"] == 1 else {}  # later reads would not merge

        try:
            with mock.patch.object(aliases, "load_aliases", flaky_load):
                payload = self._breakdown(conn)
        finally:
            conn.close()

        self.assertEqual(calls["n"], 1, "load_aliases must run once per breakdown")
        rows = {row["key"]: row for row in payload["rows"]}
        self.assertIn("merged-ds", rows)
        self.assertEqual(rows["merged-ds"]["value"], 10 + 20)
        self.assertEqual(rows["merged-ds"]["raw"], ["deepseek-flash", "deepseek-v4.1-flash"])
        self.assertNotIn("deepseek-flash", rows)  # not split by a mid-query change

    def test_stored_rows_are_not_rewritten(self):
        self.aliases_file.write_text(json.dumps(ALIASES), encoding="utf-8")
        conn = self._seed()
        try:
            self._breakdown(conn)
            stored = {
                row["model_raw"]
                for row in conn.execute("SELECT model_raw FROM usage_events")
            }
        finally:
            conn.close()
        self.assertEqual(
            stored,
            {"deepseek-flash", "deepseek-v4.1-flash", "deepseek-v4.1-flash:1017", "glm-5.2"},
        )

    def test_shipped_alias_file_merges_the_deepseek_names(self):
        default_table = aliases.load_aliases(aliases.DEFAULT_ALIASES_FILE, force=True)
        self.assertEqual(
            default_table.get("deepseek-flash"), "deepseek-v4.1-flash:1017"
        )
        self.assertEqual(
            default_table.get("deepseek-v4.1-flash"), "deepseek-v4.1-flash:1017"
        )


if __name__ == "__main__":
    sys.exit(unittest.main())
