"""HTTP API tests: shapes, zero-fill, cost handling, static files."""

from __future__ import annotations

import contextlib
import io
import json
import shutil
import subprocess
import sys
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest import mock

from tests.support import TempEnvTestCase
from tokenboard import db, pricing
from tokenboard import server as server_mod

NODE = shutil.which("node")

PRICING = {
    "_comment": "test table; keys starting with _ are ignored",
    "claude-opus-5-5": {"input": 4.0, "output": 20.0, "cache_read": 0.2, "cache_write": 8.0},
}


def insert(conn, row_id, source, ts, *, model=None, provider=None, cost_log=None,
           input_=0, output=0, cache_read=0, cache_write=0, device="testhost",
           project="/tmp/proj"):
    db.insert_event(
        conn,
        {
            "id": row_id,
            "source": source,
            "ts": ts,
            "provider": provider,
            "model_raw": model,
            "model": db.normalize_model(model),
            "project": project,
            "device": device,
            "input": input_,
            "output": output,
            "cache_read": cache_read,
            "cache_write": cache_write,
            "cost_log": cost_log,
        },
    )


class ServerTestCase(TempEnvTestCase):
    def setUp(self):
        super().setUp()
        self.pricing_file = self.root / "pricing.json"
        self.pricing_file.write_text(json.dumps(PRICING), encoding="utf-8")
        self._pricing_patch = self.enterContext_patch("TOKENBOARD_PRICING", str(self.pricing_file))
        self.today = db.local_today()
        self.day0 = (self.today - __import__("datetime").timedelta(days=2)).isoformat()
        self.day1 = (self.today - __import__("datetime").timedelta(days=1)).isoformat()
        self.day2 = self.today.isoformat()
        self._seed()
        self.server = server_mod.make_server(
            port=0, ingest_interval=0, run_ingest=False
        )
        self.thread = threading.Thread(
            target=self.server.serve_forever,
            kwargs={"poll_interval": 0.05},  # fast shutdown between tests
            daemon=True,
        )
        self.thread.start()
        self.addCleanup(self._stop_server)
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def enterContext_patch(self, key, value):
        import os
        from unittest import mock

        patcher = mock.patch.dict(os.environ, {key: value})
        patcher.start()
        self.addCleanup(patcher.stop)
        return patcher

    def _stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def _seed(self):
        conn = db.connect()
        try:
            # pi: log-recorded cost, unknown model (openai/... normalizes to deepseek-v3)
            insert(conn, "pi:1", "pi", f"{self.day1}T02:00:00.000Z",
                   model="openai/gpt-5/DeepSeek-V3", provider="deepseek",
                   cost_log=0.5, input_=100, output=10, cache_read=5, cache_write=1)
            insert(conn, "pi:2", "pi", f"{self.day2}T03:00:00.000Z",
                   model="openai/gpt-5/DeepSeek-V3", provider="deepseek",
                   cost_log=0.25, input_=200, output=20)
            # claude-code: no logged cost -> priced from pricing.json
            insert(conn, "claude-code:1", "claude-code", f"{self.day2}T04:00:00.000Z",
                   model="claude-opus-5-5", provider="anthropic",
                   input_=1000, output=100, cache_read=2000, cache_write=300)
            # codex: model missing from pricing.json -> unknown cost
            insert(conn, "codex:1", "codex", f"{self.day2}T05:00:00.000Z",
                   model="gpt-6-astra", provider="openai",
                   input_=400, output=40, cache_read=100, cache_write=0)
            conn.commit()
        finally:
            conn.close()

    # -- helpers -----------------------------------------------------------
    def get(self, path: str):
        with urllib.request.urlopen(self.base + path, timeout=10) as response:
            return response.status, response.read()

    def get_json(self, path: str):
        status, body = self.get(path)
        return status, json.loads(body.decode("utf-8"))

    def post_json(self, path: str, payload=None):
        data = json.dumps(payload or {}).encode("utf-8")
        request = urllib.request.Request(
            self.base + path, data=data, method="POST",
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.loads(response.read().decode("utf-8"))

    def window(self):
        return f"start={self.day0}&end={self.day2}"


class MetaAndStaticTests(ServerTestCase):
    def test_meta_shape(self):
        status, meta = self.get_json("/api/meta")
        self.assertEqual(status, 200)
        self.assertEqual(
            sorted(meta), ["devices", "first_day", "last_day", "last_ingest_at", "sources"]
        )
        self.assertEqual(meta["sources"], ["claude-code", "codex", "pi"])
        self.assertEqual(meta["devices"], ["testhost"])
        self.assertEqual(meta["first_day"], self.day1)
        self.assertEqual(meta["last_day"], self.day2)

    def test_index_returns_html_referencing_echarts(self):
        status, body = self.get("/")
        text = body.decode("utf-8")
        self.assertEqual(status, 200)
        self.assertIn("<!DOCTYPE html>", text)
        self.assertIn("Token 用量", text)
        self.assertIn("echarts.min.js", text)
        self.assertIn("/static/app.js", text)
        self.assertIn("/static/style.css", text)

    def test_static_assets_are_served(self):
        for name, needle in (
            ("/static/app.js", "Token 用量"),
            ("/static/style.css", "--bg"),
        ):
            status, body = self.get(name)
            self.assertEqual(status, 200, name)
            self.assertIn(needle, body.decode("utf-8"))

    def test_ui_contains_the_reviewed_behaviour(self):
        """Source-level contract for frontend fixes that have no runtime test."""
        js = (server_mod.STATIC_DIR / "app.js").read_text(encoding="utf-8")
        css = (server_mod.STATIC_DIR / "style.css").read_text(encoding="utf-8")
        html = (server_mod.STATIC_DIR / "index.html").read_text(encoding="utf-8")

        # 3. ingest button must honour HTTP status and per-source errors
        self.assertIn("if (!res.ok)", js)
        self.assertIn("stats.errors", js)
        self.assertIn('id="ingest-status"', html)
        # 4. stale responses are dropped by a generation counter
        self.assertIn("requestGen", js)
        self.assertIn("generation !== requestGen", js)
        # 7. share bars in the source tab reuse the chart colour
        self.assertIn('by === "source" ? colorFor(row.key)', js)
        self.assertIn("%;background:", js)
        self.assertNotIn("linear-gradient(90deg, #4f8cff", css)
        # 8. numeric headers align with its right-aligned cells
        self.assertIn("th.col-value", css)
        self.assertIn("th.col-cost", css)
        self.assertIn("th.col-cost-share", css)

    def test_vendored_echarts_is_served(self):
        status, body = self.get("/static/echarts.min.js")
        self.assertEqual(status, 200)
        self.assertGreater(len(body), 100_000)

    def test_unknown_path_is_404_and_traversal_is_blocked(self):
        for path in ("/nope", "/static/../tokenboard/db.py"):
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                self.get(path)
            self.assertIn(ctx.exception.code, (403, 404))


class DailyTests(ServerTestCase):
    def test_daily_zero_fills_and_splits_by_source(self):
        status, daily = self.get_json(f"/api/daily?{self.window()}&metric=io")
        self.assertEqual(status, 200)
        self.assertEqual(sorted(daily), ["days", "series"])
        self.assertEqual(daily["days"], [self.day0, self.day1, self.day2])
        self.assertEqual(sorted(daily["series"]), ["claude-code", "codex", "pi"])
        for source, values in daily["series"].items():
            self.assertEqual(len(values), 3, source)
        # day0 has no rows at all -> zeros everywhere
        self.assertEqual([daily["series"][s][0] for s in daily["series"]], [0, 0, 0])
        self.assertEqual(daily["series"]["pi"], [0, 110, 220])
        self.assertEqual(daily["series"]["claude-code"], [0, 0, 1100])
        self.assertEqual(daily["series"]["codex"], [0, 0, 440])

    def test_daily_total_includes_cache(self):
        _, daily = self.get_json(f"/api/daily?{self.window()}&metric=total")
        self.assertEqual(daily["series"]["pi"], [0, 116, 220])
        self.assertEqual(daily["series"]["claude-code"], [0, 0, 1000 + 100 + 2000 + 300])
        self.assertEqual(daily["series"]["codex"], [0, 0, 400 + 40 + 100])

    def test_daily_cost_uses_pricing_and_logged_cost(self):
        _, daily = self.get_json(f"/api/daily?{self.window()}&metric=cost")
        # pi: logged costs 0.5 and 0.25
        self.assertAlmostEqual(daily["series"]["pi"][1], 0.5, places=6)
        self.assertAlmostEqual(daily["series"]["pi"][2], 0.25, places=6)
        # claude-code: 1000*4/1e6 + 100*20/1e6 + 2000*0.2/1e6 + 300*8/1e6
        expected = (1000 * 4.0 + 100 * 20.0 + 2000 * 0.2 + 300 * 8.0) / 1e6
        self.assertAlmostEqual(daily["series"]["claude-code"][2], round(expected, 6), places=6)
        # codex model is unlisted -> unknown cost counted as 0
        self.assertEqual(daily["series"]["codex"][2], 0)

    def test_default_range_is_last_30_days(self):
        _, daily = self.get_json("/api/daily?metric=io")
        self.assertEqual(len(daily["days"]), 30)
        self.assertEqual(daily["days"][-1], self.today.isoformat())

    def test_daily_matches_the_cli_summary_series(self):
        # The API and `tokenboard summary` must agree column by column.
        _, daily = self.get_json(f"/api/daily?{self.window()}&metric=io")
        conn = db.connect()
        try:
            cli = db.query_daily(conn, self.day0, self.day2, "io")
        finally:
            conn.close()
        self.assertEqual(daily["days"], cli["days"])
        for source, values in cli["series"].items():
            self.assertEqual(daily["series"][source], values, source)

    def test_cost_daily_series_sums_to_the_breakdown_total(self):
        _, daily = self.get_json(f"/api/daily?{self.window()}&metric=cost")
        _, breakdown = self.get_json(
            f"/api/breakdown?{self.window()}&metric=cost&by=source"
        )
        self.assertAlmostEqual(
            sum(sum(values) for values in daily["series"].values()),
            breakdown["cost_total"],
            places=5,
        )

    def test_invalid_params_are_rejected(self):
        for query in (
            "metric=bogus",
            "start=not-a-date&end=2026-01-01",
            "start=2026-05-01&end=2026-04-01",
        ):
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                self.get("/api/daily?" + query)
            self.assertEqual(ctx.exception.code, 400, query)

    def test_dates_are_strict_yyyy_mm_dd(self):
        # Compact ISO (accepted by date.fromisoformat), ISO week dates and
        # 1-digit fields must all be rejected rather than silently parsed.
        for query in (
            "start=20261101&end=2026-11-01",
            "start=2026-W44-1&end=2026-11-01",
            "start=2026-11-1&end=2026-11-01",
            "start=2026/11/01&end=2026-11-01",
            "start=2026-02-30&end=2026-03-01",
            "start=2026-11-01T00:00:00&end=2026-11-01",
            "end=20261101",
            "end=0001-01-01",
            "start=0001-01-01&end=9999-12-31",
        ):
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                self.get("/api/daily?" + query)
            self.assertEqual(ctx.exception.code, 400, query)

    def test_date_boundaries_are_accepted(self):
        # Single-day ranges at the edges of the calendar stay valid.
        for query in (
            "start=0001-01-01&end=0001-01-01",
            "start=9999-12-31&end=9999-12-31",
            f"start={self.day2}&end={self.day2}",
        ):
            status, daily = self.get_json("/api/daily?" + query + "&metric=io")
            self.assertEqual(status, 200, query)
            self.assertEqual(len(daily["days"]), 1, query)


class BreakdownTests(ServerTestCase):
    def _breakdown(self, by: str, metric: str = "io"):
        status, payload = self.get_json(
            f"/api/breakdown?{self.window()}&metric={metric}&by={by}"
        )
        self.assertEqual(status, 200)
        return payload

    def test_shape_and_sorted_desc(self):
        payload = self._breakdown("source")
        self.assertEqual(
            sorted(payload),
            ["cost_any_known", "cost_partial", "cost_total", "rows", "total"],
        )
        self.assertEqual(sorted(payload["rows"][0]), [
            "cost", "cost_any_known", "cost_known", "cost_partial", "cost_share",
            "key", "raw", "share", "value",
        ])
        values = [row["value"] for row in payload["rows"]]
        self.assertEqual(values, sorted(values, reverse=True))
        self.assertAlmostEqual(sum(row["share"] for row in payload["rows"]), 1.0, places=6)
        self.assertEqual(payload["total"], 110 + 220 + 1100 + 440)

    def test_all_four_dimensions(self):
        expected_keys = {
            "source": {"pi", "claude-code", "codex"},
            "model": {"deepseek-v3", "claude-opus-5-5", "gpt-6-astra"},
            "device": {"testhost"},
            "project": {"/tmp/proj"},
        }
        for by, keys in expected_keys.items():
            payload = self._breakdown(by)
            self.assertEqual({row["key"] for row in payload["rows"]}, keys, by)
            self.assertAlmostEqual(
                sum(row["share"] for row in payload["rows"]), 1.0, places=6, msg=by
            )

    def test_raw_lists_models_and_providers(self):
        by_model = {row["key"]: row for row in self._breakdown("model")["rows"]}
        self.assertEqual(by_model["deepseek-v3"]["raw"], ["openai/gpt-5/DeepSeek-V3"])
        self.assertEqual(by_model["claude-opus-5-5"]["raw"], ["claude-opus-5-5"])

        by_source = {row["key"]: row for row in self._breakdown("source")["rows"]}
        self.assertEqual(by_source["pi"]["raw"], ["deepseek"])
        self.assertEqual(by_source["codex"]["raw"], ["openai"])
        self.assertEqual(by_source["claude-code"]["raw"], ["anthropic"])

        # device/project have no raw names to list
        self.assertEqual(self._breakdown("device")["rows"][0]["raw"], [])

    def test_cost_totals_and_partial_flag(self):
        payload = self._breakdown("model", metric="cost")
        self.assertTrue(payload["cost_partial"])  # codex model is unpriced
        by_model = {row["key"]: row for row in payload["rows"]}
        self.assertAlmostEqual(by_model["deepseek-v3"]["cost"], 0.75, places=6)
        claude_expected = round(
            (1000 * 4.0 + 100 * 20.0 + 2000 * 0.2 + 300 * 8.0) / 1e6, 6
        )
        self.assertAlmostEqual(by_model["claude-opus-5-5"]["cost"], claude_expected, places=6)
        self.assertEqual(by_model["gpt-6-astra"]["cost"], 0.0)
        self.assertFalse(by_model["gpt-6-astra"]["cost_known"])
        self.assertTrue(by_model["deepseek-v3"]["cost_known"])
        self.assertAlmostEqual(by_model["deepseek-v3"]["cost_share"], 0.75 / payload["cost_total"], places=6)
        self.assertEqual(payload["total"], 0.75 + claude_expected)

    def test_raw_names_survive_a_comma_in_the_model_string(self):
        # GROUP_CONCAT + split(",") used to mangle this into two fake names.
        conn = db.connect()
        try:
            insert(conn, "codex:comma", "codex", f"{self.day2}T06:00:00.000Z",
                   model="vendor/Model,Comma", provider="openai,inc",
                   input_=10, output=1)
            conn.commit()
        finally:
            conn.close()
        by_model = {row["key"]: row for row in self._breakdown("model")["rows"]}
        self.assertIn("model,comma", by_model)
        self.assertEqual(by_model["model,comma"]["raw"], ["vendor/Model,Comma"])
        by_source = {row["key"]: row for row in self._breakdown("source")["rows"]}
        self.assertIn("openai,inc", by_source["codex"]["raw"])

    def test_row_level_cost_partial_flags(self):
        # One pi row is logged-cost-only (always known), claude-code is priced,
        # codex is unpriced: only the codex row may be flagged partial.
        payload = self._breakdown("model", metric="cost")
        by_model = {row["key"]: row for row in payload["rows"]}
        self.assertFalse(by_model["gpt-6-astra"]["cost_known"])
        self.assertTrue(by_model["gpt-6-astra"]["cost_partial"])
        self.assertTrue(by_model["claude-opus-5-5"]["cost_known"])
        self.assertFalse(by_model["claude-opus-5-5"]["cost_partial"])
        self.assertTrue(payload["cost_any_known"])

    def test_cost_any_known_is_false_when_nothing_is_priced(self):
        conn = db.connect()
        try:
            # Drop every priced/logged row, leaving only the unpriced codex model.
            conn.execute(
                "DELETE FROM usage_events WHERE source IN ('pi', 'claude-code')"
            )
            conn.commit()
        finally:
            conn.close()
        payload = self._breakdown("source", metric="cost")
        self.assertFalse(payload["cost_any_known"])
        self.assertTrue(payload["cost_partial"])
        self.assertEqual(payload["cost_total"], 0)
        self.assertFalse(payload["rows"][0]["cost_known"])

    def test_cli_cost_series_matches_the_api_breakdown_cost(self):
        # Finding: the CLI used COALESCE(cost_log, 0) while the API priced rows.
        # Both now go through db.COST_EXPR / pricing.cost, so they must agree.
        _, breakdown = self.get_json(
            f"/api/breakdown?{self.window()}&metric=cost&by=source"
        )
        api_cost = {row["key"]: row["cost"] for row in breakdown["rows"]}
        conn = db.connect()
        try:
            cli = db.query_daily(conn, self.day0, self.day2, "cost")
        finally:
            conn.close()
        for source, values in cli["series"].items():
            self.assertAlmostEqual(sum(values), api_cost[source], places=6, msg=source)
        self.assertEqual(bool(cli["cost_partial"]), breakdown["cost_partial"])
        self.assertEqual(bool(cli["cost_any_known"]), breakdown["cost_any_known"])
        # And the priced claude rows really are non-zero (the original bug).
        self.assertGreater(sum(cli["series"]["claude-code"]), 0)

    def test_cost_partial_false_when_every_row_is_priced(self):
        conn = db.connect()
        try:
            conn.execute("DELETE FROM usage_events WHERE source = 'codex'")
            conn.commit()
        finally:
            conn.close()
        pricing.load_pricing(force=True)
        payload = self._breakdown("source", metric="cost")
        self.assertFalse(payload["cost_partial"])
        self.assertAlmostEqual(sum(row["cost_share"] for row in payload["rows"]), 1.0, places=6)

    def test_invalid_by_is_rejected(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            self.get(f"/api/breakdown?{self.window()}&by=bogus")
        self.assertEqual(ctx.exception.code, 400)


class MixedCostGroupTests(ServerTestCase):
    """Groups that mix priced and unpriced events must keep their known subtotal."""

    def _breakdown(self, by, metric="io"):
        status, payload = self.get_json(
            f"/api/breakdown?{self.window()}&metric={metric}&by={by}"
        )
        self.assertEqual(status, 200)
        return payload

    def _add(self, row_id, source, model, cost_log, *, device="mixed-dev",
             project="/tmp/mixed", input_=100):
        conn = db.connect()
        try:
            insert(conn, row_id, source, f"{self.day2}T07:00:00.000Z",
                   model=model, provider="prov", cost_log=cost_log,
                   input_=input_, device=device, project=project)
            conn.commit()
        finally:
            conn.close()

    def test_mixed_group_keeps_known_cost_by_device_and_project(self):
        # Priced claude row + unpriced codex row inside one device and project.
        self._add("mix:claude", "claude-code", "claude-opus-5-5", None, input_=1000)
        self._add("mix:codex", "codex", "gpt-6-astra", None, input_=400)
        expected = round(1000 * 4.0 / 1e6, 6)  # only the priced row contributes

        for by, key in (("device", "mixed-dev"), ("project", "/tmp/mixed")):
            payload = self._breakdown(by)
            row = [r for r in payload["rows"] if r["key"] == key][0]
            self.assertTrue(row["cost_any_known"], by)
            self.assertTrue(row["cost_partial"], by)
            self.assertFalse(row["cost_known"], by)  # compatibility field
            self.assertGreater(row["cost"], 0, by)
            self.assertAlmostEqual(row["cost"], expected, places=6, msg=by)

    def test_group_with_no_priced_row_reports_nothing_known(self):
        self._add("only:codex", "codex", "gpt-6-astra", None, device="unpriced-dev",
                  project="/tmp/unpriced")
        row = [
            r for r in self._breakdown("device")["rows"] if r["key"] == "unpriced-dev"
        ][0]
        self.assertFalse(row["cost_any_known"])
        self.assertTrue(row["cost_partial"])
        self.assertEqual(row["cost"], 0)

    def test_logged_zero_cost_counts_as_known(self):
        # A logged cost of 0.0 is known (not NULL): subtotal 0 but not unknown.
        self._add("zero:pi", "pi", "deepseek-v3", 0.0, device="zero-dev",
                  project="/tmp/zero")
        self._add("zero:codex", "codex", "gpt-6-astra", None, device="zero-dev",
                  project="/tmp/zero")
        row = [
            r for r in self._breakdown("device")["rows"] if r["key"] == "zero-dev"
        ][0]
        self.assertTrue(row["cost_any_known"])
        self.assertTrue(row["cost_partial"])
        self.assertEqual(row["cost"], 0)


class UiCostFormattingTests(unittest.TestCase):
    """Run the real cell-formatting code in node (skipped when node is absent)."""

    APP_JS = server_mod.STATIC_DIR / "app.js"

    def _format(self, row):
        script = (
            f"const f = require({json.dumps(str(self.APP_JS))});"
            f"console.log(JSON.stringify(f.formatCostCells({json.dumps(row)})));"
        )
        result = subprocess.run(
            [NODE, "-e", script], capture_output=True, text=True, timeout=30
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    @unittest.skipUnless(NODE, "node binary not available")
    def test_mixed_row_shows_known_subtotal_with_partial_marker(self):
        # Regression: this used to render "—" because cost_known was false.
        cells = self._format(
            {"cost": 4.0, "cost_share": 0.5, "cost_any_known": True,
             "cost_partial": True, "cost_known": False}
        )
        self.assertEqual(cells["cost"], "$4.00 <span class=\"partial\">部分</span>")
        self.assertIn("50.0%", cells["costShare"])
        self.assertIn("部分", cells["costShare"])
        self.assertTrue(cells["partial"])

    @unittest.skipUnless(NODE, "node binary not available")
    def test_fully_priced_row_has_no_marker(self):
        cells = self._format(
            {"cost": 2.0, "cost_share": 0.25, "cost_any_known": True,
             "cost_partial": False, "cost_known": True}
        )
        self.assertEqual(cells["cost"], "$2.00")
        self.assertEqual(cells["costShare"], "25.0%")
        self.assertFalse(cells["partial"])

    @unittest.skipUnless(NODE, "node binary not available")
    def test_unpriced_row_shows_dash(self):
        cells = self._format(
            {"cost": 0, "cost_share": 0, "cost_any_known": False,
             "cost_partial": True, "cost_known": False}
        )
        self.assertEqual(cells["cost"], "—")
        self.assertEqual(cells["costShare"], "—")

    @unittest.skipUnless(NODE, "node binary not available")
    def test_payload_without_cost_any_known_falls_back_to_cost_known(self):
        cells = self._format({"cost": 1.5, "cost_share": 0.1, "cost_known": True})
        self.assertEqual(cells["cost"], "$1.50")
        self.assertEqual(cells["costShare"], "10.0%")


class IngestStartupTests(TempEnvTestCase):
    """The initial ingest must never stop the server from starting."""

    def test_failed_initial_ingest_still_serves_and_retries(self):
        calls = {"n": 0}
        real_ingest = server_mod.ingest_mod.ingest
        retry_entered = threading.Event()  # a retry reached the parser
        release_retry = threading.Event()  # test decides when it may finish

        def gated_ingest(*args, **kwargs):
            calls["n"] += 1
            if calls["n"] == 1:
                raise RuntimeError("simulated ingest failure")
            retry_entered.set()
            release_retry.wait(15)  # hold the retry so the assertions are stable
            return real_ingest(*args, **kwargs)

        patcher = mock.patch.object(server_mod.ingest_mod, "ingest", gated_ingest)
        patcher.start()
        self.addCleanup(patcher.stop)
        quiet = contextlib.redirect_stdout(io.StringIO())  # expected failure log
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)
        server = server_mod.make_server(port=0, ingest_interval=0.05, run_ingest=True)
        self.addCleanup(release_retry.set)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        thread = threading.Thread(
            target=server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True
        )
        thread.start()
        self.addCleanup(thread.join, 5)

        # Wait deterministically until the background worker is inside the retry.
        self.assertTrue(retry_entered.wait(10), "background ingest never retried")
        self.assertIsNone(server.last_result)  # held mid-flight, not finished

        # Startup survived the first exception and keeps serving while held.
        base = f"http://127.0.0.1:{server.server_address[1]}"
        with urllib.request.urlopen(base + "/api/meta", timeout=10) as response:
            self.assertEqual(response.status, 200)
            meta = json.loads(response.read().decode("utf-8"))
        self.assertIn("sources", meta)
        self.assertIsNone(server.last_result)

        # Release the retry: it finishes and the schedule keeps going.
        release_retry.set()
        deadline = time.time() + 10
        while server.last_result is None and time.time() < deadline:
            time.sleep(0.02)
        self.assertIsNotNone(server.last_result, "retry never completed")
        self.assertGreaterEqual(calls["n"], 2)
        self.assertIn("sources", server.last_result)


class IngestEndpointTests(ServerTestCase):
    def test_post_ingest_returns_counts(self):
        status, payload = self.post_json("/api/ingest")
        self.assertEqual(status, 200)
        for key in ("sources", "rows", "scanned", "changed", "errors", "total_rows", "ingested_at"):
            self.assertIn(key, payload)
        self.assertEqual(payload["errors"], 0)
        # temp source dirs are empty, so nothing new can arrive
        self.assertEqual(payload["rows"], 0)
        _, meta = self.get_json("/api/meta")
        self.assertIsNotNone(meta["last_ingest_at"])

    def test_get_ingest_is_rejected(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            self.get("/api/ingest")
        self.assertEqual(ctx.exception.code, 405)


class PricingTests(unittest.TestCase):
    """pricing.py units: comment keys, lookup by normalized name, unknown models."""

    def setUp(self):
        import tempfile

        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.path = Path(self._tmp.name) / "pricing.json"
        self.path.write_text(json.dumps(PRICING), encoding="utf-8")
        self.table = pricing.load_pricing(self.path, force=True)

    def test_comment_keys_are_ignored(self):
        self.assertEqual(list(self.table), ["claude-opus-5-5"])

    def test_cost_prefers_logged_value(self):
        row = {"model": "claude-opus-5-5", "input": 1_000_000, "cost_log": 9.99}
        self.assertEqual(pricing.cost(row, self.table), 9.99)

    def test_cost_estimates_from_prices(self):
        row = {
            "model": "claude-opus-5-5",
            "input": 1_000_000,
            "output": 1_000_000,
            "cache_read": 1_000_000,
            "cache_write": 1_000_000,
        }
        self.assertAlmostEqual(pricing.cost(row, self.table), 4.0 + 20.0 + 0.2 + 8.0)

    def test_cost_is_none_for_unlisted_models(self):
        self.assertIsNone(pricing.cost({"model": "gpt-6-astra", "input": 10}, self.table))
        self.assertIsNone(
            pricing.cost({"model_raw": "openai/gpt-5/DeepSeek-V3", "input": 10}, self.table)
        )

    def test_missing_file_means_no_prices(self):
        missing = Path(self._tmp.name) / "nope.json"
        self.assertEqual(pricing.load_pricing(missing, force=True), {})


if __name__ == "__main__":
    sys.exit(unittest.main())
