"""Source registry.

Each source module exposes ``NAME``, ``roots()``, ``iter_files(root)`` and
``parse_file(path, device)`` (yielding dicts whose keys are usage_events
columns).
"""

from __future__ import annotations

from . import claude_code, codex, pi

SOURCES = (pi, claude_code, codex)
SOURCE_NAMES = tuple(source.NAME for source in SOURCES)
BY_NAME = {source.NAME: source for source in SOURCES}

__all__ = ["SOURCES", "SOURCE_NAMES", "BY_NAME"]
