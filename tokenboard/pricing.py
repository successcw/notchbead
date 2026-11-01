"""Cost model: USD prices per 1M tokens from ``pricing.json``.

``cost(row)`` follows the SPEC metric table: the cost recorded by the log itself
wins; otherwise the row is priced from ``pricing.json``; when the model is not
listed the cost is *unknown* (``None``), so callers can exclude it from totals
and flag the total as partial.

``pricing.json`` lives next to this module and is user-editable. Keys starting
with ``_`` are comments. ``TOKENBOARD_PRICING`` points at an alternative file
(tests use a temporary one).
"""

from __future__ import annotations

import json
import os
from pathlib import Path

DEFAULT_PRICING_FILE = Path(__file__).with_name("pricing.json")
COUNTERS = ("input", "output", "cache_read", "cache_write")
PER_TOKENS = 1_000_000.0

_cache: dict = {"key": None, "table": {}}


def pricing_path() -> Path:
    """Pricing file to use (``TOKENBOARD_PRICING`` overrides)."""
    override = os.environ.get("TOKENBOARD_PRICING")
    if override:
        return Path(override).expanduser()
    return DEFAULT_PRICING_FILE


def _parse_table(raw: dict) -> dict:
    table: dict[str, dict[str, float]] = {}
    for model, prices in raw.items():
        if not isinstance(model, str) or model.startswith("_"):
            continue  # "_comment" and friends are documentation
        if not isinstance(prices, dict):
            continue
        entry: dict[str, float] = {}
        for counter in COUNTERS:
            value = prices.get(counter)
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                value = 0.0
            entry[counter] = float(value)
        table[model.strip().lower()] = entry
    return table


def load_pricing(path: str | Path | None = None, force: bool = False) -> dict:
    """Return ``{model: {input, output, cache_read, cache_write}}``.

    The table is cached and re-read when the file changes (the user edits it by
    hand while the server runs). A missing or unreadable file means "no prices",
    which makes every estimate unknown instead of failing the request.
    """
    target = Path(path) if path is not None else pricing_path()
    try:
        stat = target.stat()
        key = (str(target), stat.st_size, stat.st_mtime)
    except OSError:
        return {}
    if not force and _cache["key"] == key:
        return _cache["table"]
    try:
        with target.open("r", encoding="utf-8") as handle:
            raw = json.load(handle)
        table = _parse_table(raw) if isinstance(raw, dict) else {}
    except (OSError, ValueError):
        table = {}
    _cache["key"] = key
    _cache["table"] = table
    return table


def price_for(model: str | None, table: dict | None = None) -> dict[str, float] | None:
    """Per-1M prices for a normalized model name, or None when unlisted."""
    if not model:
        return None
    prices = (load_pricing() if table is None else table).get(model.strip().lower())
    return prices or None


def estimate(row: dict, table: dict | None = None) -> float | None:
    """Price a single usage row from ``pricing.json``; None when unknown."""
    prices = price_for(row.get("model") or row.get("model_raw"), table)
    if prices is None:
        return None
    total = 0.0
    for counter in COUNTERS:
        try:
            tokens = float(row.get(counter) or 0)
        except (TypeError, ValueError):
            tokens = 0.0
        total += tokens * prices.get(counter, 0.0) / PER_TOKENS
    return total


def cost(row: dict, table: dict | None = None) -> float | None:
    """USD cost of one usage row: logged cost, else estimate, else None."""
    logged = row.get("cost_log")
    if logged is not None and logged != "":
        try:
            return float(logged)
        except (TypeError, ValueError):
            pass
    return estimate(row, table)


def register_cost_function(conn, table: dict | None = None, name: str = "row_cost") -> None:
    """Register :func:`cost` on a connection as the SQL function ``row_cost``.

    The CLI and the web API both price rows through this one function, so
    ``summary --metric cost`` and ``/api/breakdown?metric=cost`` cannot drift.
    """
    conn.create_function(name, 6, sql_cost(table), deterministic=True)


def sql_cost(table: dict | None = None):
    """Return a SQLite UDF computing :func:`cost` from raw column values."""

    def row_cost(cost_log, model, input_tokens, output_tokens, cache_read, cache_write):
        row = {
            "cost_log": cost_log,
            "model": model,
            "input": input_tokens,
            "output": output_tokens,
            "cache_read": cache_read,
            "cache_write": cache_write,
        }
        return cost(row, table)

    return row_cost
