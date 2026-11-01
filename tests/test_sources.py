"""Per-source parsing rules from docs/SPEC.md."""

from __future__ import annotations

import json
import shutil
import sys
import unittest

from tokenboard import ingest as ingest_mod
from tests.support import (
    FIXTURES,
    TempEnvTestCase,
    codex_session_meta,
    codex_token_count,
    zstd_compress,
)


class PiSourceTests(TempEnvTestCase):
    def test_fork_copies_are_counted_once(self):
        self.put_pi("fork_parent.jsonl", "fork_copy.jsonl")
        stats = self.run_ingest()
        self.assertEqual(stats["sources"]["pi"]["rows"], 2)
        self.assertEqual(self.row_count(), 2)
        ids = [row["id"] for row in self.rows()]
        self.assertEqual(len(set(ids)), 2)

    def test_fork_copy_keeps_one_row_per_entry(self):
        self.put_pi("fork_parent.jsonl", "fork_copy.jsonl")
        self.run_ingest()
        shared = [
            row
            for row in self.rows()
            if row["id"].endswith("aaa11111:2026-11-01T00:00:01.000Z")
        ]
        self.assertEqual(len(shared), 1)
        # INSERT OR IGNORE keeps the first file ingested; either session cwd is valid.
        self.assertIn(shared[0]["project"], {"/tmp/proj-parent", "/tmp/proj-fork"})
        fork_only = [
            row
            for row in self.rows()
            if row["id"].endswith("bbb22222:2026-11-01T00:10:05.000Z")
        ]
        self.assertEqual(len(fork_only), 1)
        self.assertEqual(fork_only[0]["project"], "/tmp/proj-fork")
        self.assertEqual(fork_only[0]["session_id"], "sess-fork")

    def test_field_mapping_and_model_normalization(self):
        self.put_pi("fork_parent.jsonl")
        self.run_ingest()
        row = self.only_row()
        self.assertEqual(row["source"], "pi")
        self.assertEqual(row["ts"], "2026-11-01T00:00:01.000Z")
        self.assertEqual(row["provider"], "deepseek")
        self.assertEqual(row["model_raw"], "openai/gpt-5/DeepSeek-V3")
        self.assertEqual(row["model"], "deepseek-v3")
        self.assertEqual(row["project"], "/tmp/proj-parent")
        self.assertEqual(row["device"], "testhost")
        self.assertEqual(row["input"], 100)
        self.assertEqual(row["output"], 10)
        self.assertEqual(row["cache_read"], 5)
        self.assertEqual(row["cache_write"], 1)
        self.assertEqual(row["reasoning"], 2)
        self.assertAlmostEqual(row["cost_log"], 0.0011)

    def test_headerless_file_is_skipped(self):
        self.put_pi("no_header.jsonl")
        stats = self.run_ingest()
        self.assertEqual(stats["sources"]["pi"]["rows"], 0)
        self.assertEqual(self.row_count(), 0)

    def test_large_line_is_parsed(self):
        big_text = "x" * (1_500_000)  # ~1.5 MB on a single line
        header = {
            "type": "session",
            "version": 3,
            "id": "sess-big",
            "timestamp": "2026-11-01T06:00:00.000Z",
            "cwd": "/tmp/proj-big",
        }
        entry = {
            "type": "message",
            "id": "ddd44444",
            "parentId": None,
            "timestamp": "2026-11-01T06:00:01.000Z",
            "message": {
                "role": "assistant",
                "provider": "deepseek",
                "model": "deepseek-v3",
                "content": [{"type": "text", "text": big_text}],
                "usage": {
                    "input": 1234,
                    "output": 56,
                    "cacheRead": 7,
                    "cacheWrite": 0,
                    "reasoning": 1,
                },
            },
        }
        self.write_pi("big.jsonl", [json.dumps(header), json.dumps(entry)])
        self.run_ingest()
        row = self.only_row()
        self.assertEqual(row["input"], 1234)
        self.assertEqual(row["output"], 56)


class ClaudeSourceTests(TempEnvTestCase):
    def test_multiline_response_counted_once(self):
        self.put_claude("multiline.jsonl")
        self.run_ingest()
        rows = self.rows()
        self.assertEqual(len(rows), 2)
        first = rows[0]
        self.assertEqual(first["id"], "claude-code:msg_abc:req_1")
        self.assertEqual(first["input"], 2)
        self.assertEqual(first["output"], 341)
        self.assertEqual(first["cache_read"], 5)
        self.assertEqual(first["cache_write"], 38913)
        self.assertEqual(first["reasoning"], 130)
        self.assertEqual(first["provider"], "anthropic")
        self.assertEqual(first["model"], "claude-opus-5-5")
        self.assertEqual(first["project"], "/tmp/proj-claude")
        self.assertEqual(first["session_id"], "sess-claude")
        self.assertIsNone(first["cost_log"])

    def test_synthetic_model_is_skipped(self):
        self.put_claude("synthetic.jsonl")
        stats = self.run_ingest()
        self.assertEqual(stats["sources"]["claude-code"]["rows"], 0)
        self.assertEqual(self.row_count(), 0)

    def test_missing_thinking_details_is_tolerated(self):
        self.put_claude("multiline.jsonl")
        self.run_ingest()
        second = [row for row in self.rows() if row["id"].endswith("msg_def:req_2")][0]
        self.assertEqual(second["reasoning"], 0)
        self.assertEqual(second["model"], "claude-opus-5-5")


class CodexSourceTests(TempEnvTestCase):
    def test_prefers_token_usage_record_and_subtracts_cache(self):
        self.put_codex("preferred.jsonl")
        self.run_ingest()
        rows = self.rows()
        self.assertEqual(len(rows), 2)  # token_count line ignored
        first = rows[0]
        self.assertEqual(first["id"], "codex:resp_1")
        self.assertEqual(first["input"], 24704 - 21632)
        self.assertEqual(first["cache_read"], 21632)
        self.assertEqual(first["cache_write"], 0)
        self.assertEqual(first["output"], 270)
        self.assertEqual(first["model_raw"], "gpt-6-astra")
        self.assertEqual(first["provider"], "openai")
        self.assertEqual(first["project"], "/tmp/proj-codex")
        self.assertEqual(first["session_id"], "sess-codex")
        self.assertIsNone(first["cost_log"])

    def test_latest_turn_context_model_wins(self):
        self.put_codex("preferred.jsonl")
        self.run_ingest()
        second = [row for row in self.rows() if row["id"] == "codex:resp_2"][0]
        self.assertEqual(second["model_raw"], "gpt-6-mini")
        self.assertEqual(second["cache_write"], 128)
        self.assertEqual(second["reasoning"], 40)
        self.assertEqual(second["input"], 31494 - 24832)

    def test_fallback_token_count_skips_repeats(self):
        self.put_codex("fallback.jsonl")
        self.run_ingest()
        rows = self.rows()
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["id"], "codex:sess-fallback:tc:110")
        self.assertEqual(rows[0]["input"], 100)
        self.assertEqual(rows[0]["output"], 10)
        self.assertEqual(rows[1]["id"], "codex:sess-fallback:tc:165")
        self.assertEqual(rows[1]["input"], 50 - 20)
        self.assertEqual(rows[1]["cache_read"], 20)
        self.assertEqual(rows[1]["reasoning"], 5)
        self.assertEqual(rows[1]["model_raw"], "gpt-5-codex")

    @unittest.skipUnless(shutil.which("zstd"), "zstd binary not available")
    def test_archived_zst_file_is_decompressed(self):
        zstd_compress(
            FIXTURES / "codex" / "fallback.jsonl",
            self.codex_archived / "archived-fallback.jsonl.zst",
        )
        stats = self.run_ingest()
        self.assertEqual(stats["sources"]["codex"]["scanned"], 1)
        self.assertEqual(len(self.rows()), 2)

    def test_plain_jsonl_in_archived_dir_is_read(self):
        self.put_codex("fallback.jsonl", archived=True)
        stats = self.run_ingest()
        self.assertEqual(stats["sources"]["codex"]["scanned"], 1)
        self.assertEqual(len(self.rows()), 2)

    def test_zst_under_sessions_is_ingested(self):
        # SPEC: sessions/ is recursive and includes *.jsonl.zst (compressed in place).
        source = FIXTURES / "codex" / "fallback.jsonl"
        target = zstd_compress(
            source,
            self.codex_sessions
            / "2025"
            / "11"
            / "21"
            / "rollout-2025-11-21T15-16-10-nested.jsonl.zst",
        )
        self.put_codex("preferred.jsonl")  # plain file alongside the compressed one
        stats = self.run_ingest()
        self.assertEqual(stats["sources"]["codex"]["scanned"], 2)
        self.assertEqual(stats["sources"]["codex"]["errors"], 0)
        ids = [row["id"] for row in self.rows()]
        # fallback path still applies to the compressed file (no token_usage_record).
        self.assertIn("codex:sess-fallback:tc:110", ids)
        self.assertIn("codex:sess-fallback:tc:165", ids)
        self.assertIn("codex:resp_1", ids)
        self.assertIn("codex:resp_2", ids)
        self.assertEqual(len(ids), 4)
        self.assertIn(str(target), self.ingested_paths())

    def test_corrupt_zst_fails_its_file_but_not_the_run(self):
        # A truncated archive must raise, so its partial rows are rolled back and
        # the file is retried next run; the valid neighbour is still ingested.
        bad = zstd_compress(
            FIXTURES / "codex" / "preferred.jsonl",
            self.codex_sessions / "a_bad.jsonl.zst",
            truncate_to=0.5,
        )
        good = self.put_codex  # keep the valid neighbour: copy the plain fixture
        self.put_codex("fallback.jsonl")
        good_path = self.codex_sessions / "fallback.jsonl"  # sorts after a_bad

        messages = []
        stats = ingest_mod.ingest(device="testhost", log=messages.append)
        codex = stats["sources"]["codex"]
        self.assertEqual(codex["errors"], 1)
        self.assertEqual(codex["rows"], 2)  # only the good file's rows
        ids = {row["id"] for row in self.rows()}
        # No partial rows leaked from the corrupt archive (preferred.jsonl would
        # have produced resp_1/resp_2 before the stream failed).
        self.assertEqual(ids, {"codex:sess-fallback:tc:110", "codex:sess-fallback:tc:165"})
        paths = self.ingested_paths()
        self.assertNotIn(str(bad), paths)
        self.assertIn(str(good_path), paths)

    def test_corrupt_zst_error_is_logged(self):
        bad = zstd_compress(
            FIXTURES / "codex" / "preferred.jsonl",
            self.codex_sessions / "broken.jsonl.zst",
            truncate_to=0.5,
        )
        messages = []
        stats = ingest_mod.ingest(device="testhost", log=messages.append)
        self.assertEqual(stats["sources"]["codex"]["errors"], 1)
        log_text = "\n".join(messages)
        self.assertIn("failed to parse", log_text)
        self.assertIn(str(bad), log_text)
        self.assertIn("zstd", log_text)

    def test_token_usage_record_with_null_usage_disables_fallback(self):
        # The record type alone disables the token_count fallback, even when the
        # payload carries no usable usage block.
        self.write_lines(
            self.codex_sessions,
            "null_usage.jsonl",
            [
                codex_session_meta("sess-null", ts="2026-06-29T00:00:00.000Z"),
                {
                    "timestamp": "2026-06-29T00:00:01.000Z",
                    "type": "token_usage_record",
                    "payload": {"response_id": "resp_null", "usage": None},
                },
                codex_token_count("2026-06-29T00:00:02.000Z", 110),
                codex_token_count("2026-06-29T00:00:03.000Z", 165),
            ],
        )
        stats = self.run_ingest()
        self.assertEqual(stats["sources"]["codex"]["errors"], 0)
        self.assertEqual(self.row_count(), 0)


if __name__ == "__main__":
    sys.exit(unittest.main())
