"""Model aliases: query-time merging of normalized model names.

``model_aliases.json`` maps a normalized model name (``deepseek-flash``) to the
display name used by the 模型 breakdown (``deepseek-v4.1-flash:1017``). Stored
rows are never rewritten and pricing still looks at the stored ``model`` column;
only the breakdown key is aliased, so raw names stay available for hover text.

Keys starting with ``_`` are comments. ``TOKENBOARD_ALIASES`` points at an
alternative file (tests use a temporary one). A missing or broken file simply
means "no aliases".
"""

from __future__ import annotations

import json
import os
from pathlib import Path

DEFAULT_ALIASES_FILE = Path(__file__).with_name("model_aliases.json")

_cache: dict = {"key": None, "table": {}}


def aliases_path() -> Path:
    """Alias file to use (``TOKENBOARD_ALIASES`` overrides)."""
    override = os.environ.get("TOKENBOARD_ALIASES")
    if override:
        return Path(override).expanduser()
    return DEFAULT_ALIASES_FILE


def _clean(name) -> str:
    return str(name).strip().lower()


def _parse_table(raw: dict) -> dict[str, str]:
    table: dict[str, str] = {}
    for key, value in raw.items():
        if not isinstance(key, str) or key.startswith("_"):
            continue  # "_comment" and friends are documentation
        if not isinstance(value, str) or not value.strip():
            continue
        alias = _clean(value)
        source = _clean(key)
        if source and alias and source != alias:
            table[source] = alias
    return table


def load_aliases(path: str | Path | None = None, force: bool = False) -> dict:
    """Return ``{normalized model: display name}``.

    The table is cached and re-read whenever the file's size or mtime changes,
    so editing ``model_aliases.json`` takes effect without restarting anything.
    """
    target = Path(path) if path is not None else aliases_path()
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


def alias_for(name: str | None, table: dict | None = None) -> str | None:
    """Display name for a normalized model (the name itself when unaliased)."""
    if name is None:
        return None
    table = load_aliases() if table is None else table
    return table.get(_clean(name), name)


def sql_alias(table: dict | None = None):
    """Return a SQLite UDF computing :func:`alias_for` from a model name."""

    def model_alias(name):
        return alias_for(name, table)

    return model_alias


def register_alias_function(conn, table: dict | None = None, name: str = "model_alias") -> None:
    """Register :func:`alias_for` on a connection as the SQL function ``model_alias``.

    The table is always bound as a snapshot: ``load_aliases()`` runs once here,
    never per row. ``db.query_breakdown()`` re-registers with a fresh snapshot at
    the start of each breakdown, so an edited file is picked up by the next query
    while a single query (aggregate + ``raw`` lookups) sees one consistent table.
    """
    snapshot = load_aliases() if table is None else table
    conn.create_function(name, 1, sql_alias(snapshot), deterministic=True)
