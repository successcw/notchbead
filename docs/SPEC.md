# tokenboard — spec (phase 1)

Local web service that keeps a long-term history of AI coding-agent token usage
on this Mac and shows daily trends. Phase 1 sources: **pi**, **claude-code**, **codex**,
**workbuddy**.

Hard rules
- Python 3.13 **standard library only** (sqlite3, http.server, json, subprocess…). No pip installs.
- Read-only access to agent logs. Never modify or delete anything under `~/.pi`, `~/.claude`,
  `~/.codex`, `~/.workbuddy`.
- Server binds to `127.0.0.1` only. Default port `8787`.
- Raw logs get deleted by the tools over time; the DB is the long-term record.
  Ingest must be idempotent: re-ingesting the same file never double-counts.

## Layout

```
tokenboard/
  __main__.py        CLI: ingest | summary | serve
  config.py          paths, port, device name
  db.py              schema, connect(), insert helpers, query helpers
  ingest.py          file discovery, change detection, runs sources
  pricing.py         loads pricing.json, cost for a row
  pricing.json       per-model USD prices per 1M tokens (user-editable)
  aliases.py         loads model_aliases.json, query-time model merging
  model_aliases.json normalized model name -> display name (user-editable)
  server.py          HTTP server + JSON API + static files + background ingest
  sources/
    __init__.py      SOURCES registry
    pi.py  claude_code.py  codex.py  workbuddy.py
  static/            index.html, app.js, style.css, echarts.min.js (vendored)
tests/               unittest; fixtures/ holds small synthetic JSONL files
scripts/             install.sh / uninstall.sh (launchd)
```

## Paths (config.py)

- DB: `~/Library/Application Support/tokenboard/usage.db` (override with env `TOKENBOARD_DB`).
- Log roots (override with env `TOKENBOARD_PI_DIR`, `TOKENBOARD_CLAUDE_DIR`,
  `TOKENBOARD_CODEX_DIR`, `TOKENBOARD_WORKBUDDY_DIR`):
  - pi: `~/.pi/agent/sessions` (recursive `*.jsonl`, includes `forks/` subdirs)
  - claude-code: `~/.claude/projects` (recursive `*.jsonl`, includes `subagents/`)
  - codex: `~/.codex/sessions` and `~/.codex/archived_sessions`, both recursive, both
    `*.jsonl` **and** `*.jsonl.zst` (Codex compresses older rollouts in place; they hold most of
    the history). Decompress `.zst` with `zstd -dc` via subprocess.
  - workbuddy: `~/.workbuddy/projects` (recursive `*.jsonl`; any path with a `tool-results`
    directory component is tool output and is skipped).
- Device: short hostname (`socket.gethostname().split('.')[0]`), override `TOKENBOARD_DEVICE`.
- Model aliases: `tokenboard/model_aliases.json`, override with env `TOKENBOARD_ALIASES`
  (see *Model aliases* below).

## Schema

```sql
CREATE TABLE IF NOT EXISTS usage_events (
  id          TEXT PRIMARY KEY,     -- "<source>:<dedupe key>"
  source      TEXT NOT NULL,        -- 'pi' | 'claude-code' | 'codex' | 'workbuddy'
  ts          TEXT NOT NULL,        -- UTC ISO-8601, e.g. 2026-11-01T02:19:49.838Z
  provider    TEXT,                 -- actual upstream: deepseek, ollama-cloud, anthropic, openai…
  model_raw   TEXT,                 -- model string exactly as logged
  model       TEXT,                 -- normalized (see below)
  project     TEXT,                 -- cwd of the session
  session_id  TEXT,
  device      TEXT NOT NULL,
  input       INTEGER NOT NULL DEFAULT 0,  -- uncached input only
  output      INTEGER NOT NULL DEFAULT 0,  -- includes reasoning
  cache_read  INTEGER NOT NULL DEFAULT 0,
  cache_write INTEGER NOT NULL DEFAULT 0,
  reasoning   INTEGER NOT NULL DEFAULT 0,  -- informational, already inside output
  cost_log    REAL                  -- USD cost if the log itself records it, else NULL
);
CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage_events(ts);
CREATE TABLE IF NOT EXISTS ingested_files (
  path TEXT PRIMARY KEY, source TEXT NOT NULL, size INTEGER, mtime REAL, ingested_at TEXT
);
```

Insert with `INSERT OR IGNORE`. Rows with all four token counts zero are skipped.
Days are computed at query time in local time: `date(ts, 'localtime')`.

Model normalization: take the part after the last `/`, lowercase, strip whitespace.
`model_raw` keeps the original. Aliases never change stored rows: they are applied at query time
to the `model` breakdown key only (see *Model aliases*).

## Ingest (ingest.py)

- For each source, list candidate files. Re-parse a file only if its `(size, mtime)`
  differs from `ingested_files`; then upsert that row. Parsers always read the whole file;
  `INSERT OR IGNORE` makes repeats harmless.
- A file that fails to parse is logged and skipped; it must not stop other files.
- Lines can be very long (seen up to ~4 MB). Read with plain file iteration, never with a
  fixed-size line buffer. Skip lines that are not valid JSON.
- Each source module exposes `iter_files(root) -> iterable[path]` and
  `parse_file(path, device) -> iterable[dict]` (dict keys = schema columns).

## Source rules

### pi (`~/.pi/agent/sessions/**/*.jsonl`)
- Line 1 is the header: `{"type":"session","id":…,"cwd":…}` → session_id, project.
  If line 1 is not a session header, skip the file.
- Usage rows: `type=="message"` and `message.role=="assistant"` and `message.usage` present.
- Fields: `usage.input` → input, `usage.output` → output, `usage.cacheRead` → cache_read,
  `usage.cacheWrite` → cache_write, `usage.reasoning` → reasoning, `usage.cost.total` → cost_log,
  `message.provider` → provider, `message.model` → model_raw, entry `timestamp` → ts.
- Dedupe key: `"<entry id>:<entry timestamp>"`. Forked sessions copy parent entries with the
  same id+timestamp; they must be counted once.

### claude-code (`~/.claude/projects/**/*.jsonl`)
- Usage rows: `type=="assistant"` with `message.usage`.
- Fields: `input_tokens` → input, `output_tokens` → output, `cache_read_input_tokens` →
  cache_read, `cache_creation_input_tokens` → cache_write,
  `output_tokens_details.thinking_tokens` → reasoning (if present), `message.model` → model_raw,
  provider `anthropic`, `cwd` → project, `sessionId` → session_id, `timestamp` → ts. cost_log NULL.
- One API response is written as several lines (one per content block) with the same usage.
  Dedupe key: `"<message.id>:<requestId>"`.
- Skip model `<synthetic>`.

### codex (`~/.codex/sessions/**/*.jsonl[.zst]`, `~/.codex/archived_sessions/**/*.jsonl[.zst]`)
- `session_meta.payload`: `id` → session_id, `cwd` → project, `model_provider` → provider
  (default `openai`).
- Model: the most recent `turn_context.payload.model` seen before the usage line.
- Preferred usage rows: `type=="token_usage_record"`, from `payload.usage`.
  Dedupe key: `payload.response_id`.
- Fallback, only for files that contain **no** `token_usage_record`: `event_msg` with
  `payload.type=="token_count"` and non-null `payload.info`. Use `info.last_token_usage`.
  Skip an event whose `info.total_token_usage` equals the previous one in the file (repeat).
  Dedupe key: `"<session_id>:tc:<total_token_usage.total_tokens>"`.
- Field mapping (both paths): `input_tokens` **includes** cached tokens, so
  input = `input_tokens - cached_input_tokens`, cache_read = `cached_input_tokens`,
  cache_write = `cache_write_input_tokens` (0 if absent), output = `output_tokens`,
  reasoning = `reasoning_output_tokens`. ts = the line's top-level `timestamp`. cost_log NULL.

### workbuddy (`~/.workbuddy/projects/**/*.jsonl`)

One JSON object per line (Codex/OpenAI-agents style). Skip any path with a `tool-results`
directory component, skip lines that are not valid JSON or not a dict.
- Usage rows: any line whose `providerData.rawUsage` is a dict (in practice `function_call`
  and assistant `message` lines).
- `prompt_tokens` **includes** cache reads and cache writes:
  - cache_read = max(`prompt_cache_hit_tokens`, `cache_read_input_tokens`,
    `prompt_tokens_details.cached_tokens`, `cached_tokens`)
  - cache_write = max(`cache_creation_input_tokens`, `prompt_cache_write_tokens`)
  - input = max(0, `prompt_tokens` - cache_read - cache_write)
  - output = `completion_tokens`
  - reasoning = `completion_tokens_details.reasoning_tokens`, else `completion_thinking_tokens`
- Missing/None/non-numeric counters count as 0.
- ts = the line's `timestamp` (epoch **milliseconds**, int) -> UTC ISO
  `YYYY-MM-DDTHH:MM:SS.mmmZ`. A row without a usable timestamp is skipped.
- model_raw = `providerData.model`, else `providerData.requestModelId`.
- provider = `workbuddy`, cost_log = NULL (`credit` is WorkBuddy credits, not USD).
- session_id = line `sessionId`, else the `session-meta` line's session id, else the file stem.
- project = the first top-level `cwd` seen anywhere in the file (rows may precede it, so rows are
  collected and the project is filled in before they are yielded).
- Dedupe key: `"<messageId>:<prompt_tokens>:<completion_tokens>"`. The same `messageId` can cover
  two separate calls with different usage - both count; an identical copy collapses.
  Without a `messageId`, use `sha1(<line>)[:16]`.

## Metrics (shared by CLI and API)

| key | value |
|---|---|
| `total` | input + output + cache_read + cache_write (总处理量，含 cache) |
| `io` | input + output (不含 cache) |
| `input` | input |
| `output` | output |
| `cost` | USD: `cost_log` when not NULL, else pricing.json estimate, else unknown |

Pricing (`pricing.json`): `{"<normalized model>": {"input": x, "output": y, "cache_read": z,
"cache_write": w}}`, USD per 1M tokens. Missing model → cost unknown (shown as "—", excluded
from cost totals, and the UI notes the total is partial).

## Model aliases (query-time merge)

`tokenboard/model_aliases.json` maps a normalized model name to the display name used by the
`by=model` breakdown (file override: `TOKENBOARD_ALIASES`). Keys starting with `_` are comments;
keys and values are lowercased and trimmed. Loading and caching mirror `pricing.py`: the file is
re-read when its size/mtime changes, and a missing or invalid file means "no aliases" (never an
error).

- `db.connect()` registers a deterministic SQLite function `model_alias(name)` that returns the
  alias or the name itself (NULL stays NULL).
- `db.BREAKDOWN_KEYS["model"]` is `model_alias(COALESCE(model, model_raw))`, so
  `deepseek-flash` and `deepseek-v4.1-flash` can share one row. `raw` still lists every distinct
  `model_raw` behind that row, for hover text.
- Stored rows are never rewritten, pricing still looks at the stored `model` column, and the
  schema version is unchanged (aliases are a query-time view).

Example:

```json
{"deepseek-flash": "deepseek-v4.1-flash:1017",
 "deepseek-v4.1-flash": "deepseek-v4.1-flash:1017"}
```

## CLI

- `python3 -m tokenboard ingest` → ingests all sources, prints per-source new rows / files.
- `python3 -m tokenboard summary [--days N] [--metric io]` → table: day × source.
- `python3 -m tokenboard serve [--port 8787]` → web server; ingests at start and every 300 s
  in a background thread.

## HTTP API (server.py, ThreadingHTTPServer, 127.0.0.1)

All dates are local `YYYY-MM-DD`, ranges inclusive.
- `GET /api/meta` → `{sources, devices, first_day, last_day, last_ingest_at}`
- `GET /api/daily?start=&end=&metric=` → `{days:[…], series:{<source>:[value per day]}}`,
  every day in range present (0 when empty).
- `GET /api/breakdown?start=&end=&metric=&by=source|model|device|project` →
  `{rows:[{key, value, share, cost, cost_share, raw:[distinct model_raw or provider list]}],
  total, cost_total, cost_partial: bool}` sorted by value desc.
- `POST /api/ingest` → runs ingest now, returns counts.
- `/` and `/static/*` → files from `tokenboard/static/`.

## UI (static/, Chinese labels, dark theme like the reference screenshot)

- Range buttons: 今日 / 昨日 / 近3日 / 近7日 / 近30日 / 自定义 (start + end date inputs).
- Metric select: 总处理量（含 cache）/ 输入+输出 / 仅输入 / 仅输出 / 成本 (USD).
- Stacked daily bar chart (ECharts, vendored `echarts.min.js`), one colour per source, legend on top.
- Summary line under the chart: range, metric, total, cost (marked 部分 when partial).
- Tabs: Coding Agent / 模型 / 设备 / 项目 → table: name, share bar + %, value, 成本, 成本占比.
  Show top 20, collapse the rest into "其他 N 个（合计 x%）" expandable. Hover on a model
  name shows its raw names.
- Number format: ≥1e8 → `x.xx亿`, ≥1e4 → `x.xx万`, else integer.

## Tests

`python3 -m unittest discover -s tests -t .` with synthetic fixtures covering, per source:
dedupe (pi fork copies, claude multi-line responses, codex repeated token_count), codex cached
subtraction, codex fallback path, header-less pi file skipped, a >1 MB line parsed correctly,
idempotent re-ingest (row count unchanged), API daily/breakdown shapes on a temp DB,
workbuddy field mapping/dedupe/tool-results skipping, and model-alias merging (including that an
edited alias file is picked up without reconnecting).
Tests must use temp dirs and `TOKENBOARD_DB` pointing to a temp file, never the real DB.
