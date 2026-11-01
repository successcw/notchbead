"""Shared helpers: isolated temp dirs + temp database for every test."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tokenboard import db
from tokenboard import ingest as ingest_mod

FIXTURES = Path(__file__).parent / "fixtures"


def codex_session_meta(session_id: str, cwd: str = "/tmp/proj-codex",
                       provider: str = "openai",
                       ts: str = "2026-06-29T00:00:00.000Z") -> dict:
    return {
        "timestamp": ts,
        "type": "session_meta",
        "payload": {
            "id": session_id,
            "session_id": session_id,
            "timestamp": ts,
            "cwd": cwd,
            "model_provider": provider,
        },
    }


def codex_token_count(ts: str, total_tokens: int, last: dict | None = None,
                      cumulative: dict | None = None) -> dict:
    """One ``event_msg``/``token_count`` line (the codex fallback path)."""
    last = last or {}
    usage = {
        "input_tokens": last.get("input_tokens", total_tokens),
        "cached_input_tokens": last.get("cached_input_tokens", 0),
        "cache_write_input_tokens": last.get("cache_write_input_tokens", 0),
        "output_tokens": last.get("output_tokens", 0),
        "reasoning_output_tokens": last.get("reasoning_output_tokens", 0),
        "total_tokens": total_tokens,
    }
    return {
        "timestamp": ts,
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {
                "total_token_usage": cumulative or usage,
                "last_token_usage": usage,
                "model_context_window": 258400,
            },
        },
    }


def zstd_compress(source: Path, target: Path, truncate_to: float | None = None) -> Path:
    """Compress *source* into *target*; optionally keep only a prefix of it."""
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("wb") as out:
        subprocess.run(["zstd", "-q", "-c", str(source)], stdout=out, check=True)
    if truncate_to is not None:
        data = target.read_bytes()
        target.write_bytes(data[: max(int(len(data) * truncate_to), 1)])
    return target


class TempEnvTestCase(unittest.TestCase):
    """Points every ``TOKENBOARD_*`` variable at a throwaway directory."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.pi_root = self.root / "pi"
        self.claude_root = self.root / "claude"
        self.codex_root = self.root / "codex"
        self.codex_sessions = self.codex_root / "sessions"
        self.codex_archived = self.codex_root / "archived_sessions"
        for path in (
            self.pi_root,
            self.claude_root,
            self.codex_sessions,
            self.codex_archived,
        ):
            path.mkdir(parents=True, exist_ok=True)
        self.db_path = self.root / "usage.db"
        env = {
            "TOKENBOARD_DB": str(self.db_path),
            "TOKENBOARD_PI_DIR": str(self.pi_root),
            "TOKENBOARD_CLAUDE_DIR": str(self.claude_root),
            "TOKENBOARD_CODEX_DIR": str(self.codex_root),
            "TOKENBOARD_DEVICE": "testhost",
        }
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self._assert_temp_db)

    def _assert_temp_db(self):
        # Guard against any test accidentally touching the real database.
        real = (Path.home() / "Library" / "Application Support" / "tokenboard" / "usage.db")
        self.assertFalse(str(self.db_path) == str(real))
        self.assertTrue(str(self.db_path).startswith(self.root.as_posix()))

    # -- fixture placement -------------------------------------------------
    def put_pi(self, *names: str, subdir: str = "") -> None:
        self._copy("pi", names, self.pi_root / subdir)

    def put_claude(self, *names: str, subdir: str = "") -> None:
        self._copy("claude", names, self.claude_root / subdir)

    def put_codex(self, *names: str, archived: bool = False) -> None:
        target = self.codex_archived if archived else self.codex_sessions
        self._copy("codex", names, target)

    def _copy(self, kind: str, names, target: Path) -> None:
        target.mkdir(parents=True, exist_ok=True)
        for name in names:
            shutil.copy2(FIXTURES / kind / name, target / name)

    def write_pi(self, name: str, lines, subdir: str = "") -> Path:
        target = self.pi_root / subdir
        target.mkdir(parents=True, exist_ok=True)
        path = target / name
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return path

    def write_lines(self, directory: Path, name: str, lines) -> Path:
        """Write JSON-able dicts (or raw strings) as one JSONL file."""
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / name
        body = []
        for line in lines:
            body.append(line if isinstance(line, str) else json.dumps(line))
        path.write_text("\n".join(body) + "\n", encoding="utf-8")
        return path

    def ingested_paths(self) -> set[str]:
        conn = db.connect()
        try:
            return {
                row["path"]
                for row in conn.execute("SELECT path FROM ingested_files").fetchall()
            }
        finally:
            conn.close()

    # -- actions -----------------------------------------------------------
    def run_ingest(self):
        return ingest_mod.ingest(device="testhost")

    def rows(self) -> list[dict]:
        conn = db.connect()
        try:
            return [
                dict(row)
                for row in conn.execute("SELECT * FROM usage_events ORDER BY id")
            ]
        finally:
            conn.close()

    def row_count(self) -> int:
        conn = db.connect()
        try:
            return db.event_count(conn)
        finally:
            conn.close()

    def only_row(self) -> dict:
        rows = self.rows()
        self.assertEqual(len(rows), 1, f"expected exactly one row, got {rows}")
        return rows[0]
