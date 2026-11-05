<p align="center"><img src="docs/media/promo-en.gif" alt="NotchBead demo: Bead pops out of the notch when an agent needs you; clicking today's token count opens the usage dashboard" width="100%"></p>

<p align="center"><b>English</b> · <a href="README.zh-CN.md">简体中文</a></p>

<p align="center"><sub>The demo uses made-up data. <a href="docs/media/promo-en.mp4">HD video (with sound)</a> · <a href="docs/media/dashboard.png">Dashboard screenshot</a></sub></p>

# NotchBead

A keeper for your AI coding agents that lives in the Mac notch, plus a local token-usage dashboard.

- **Notch alerts**: when an agent in Orca waits for your approval, hits an error or finishes, a WorkBuddy
  session is interrupted, or a task in the ChatGPT desktop app completes, Bead (a small blue character) pops out of the notch with a
  short chime. One click takes you straight to that window.
- **Today's usage, always visible**: the right side of the notch always shows today's tokens (such as `2.01亿`;
  亿 = 100 million).
- **Usage dashboard (tokenboard)**: collects the usage that **pi**, **claude-code**, **codex** (including the
  ChatGPT desktop app) and **workbuddy** write to their local logs into SQLite, and charts it by day, agent,
  model and project, with cost.
- **Everything stays on your Mac**: logs are read-only, the server listens on `127.0.0.1` only, nothing is
  uploaded. MIT licensed.

## Quick start

```bash
git clone https://github.com/successcw/notchbead.git
cd notchbead
scripts/install.sh          # the dashboard, as a background service: http://127.0.0.1:8787/
cd macos && make install    # the notch app, installed to /Applications
```

Needs macOS and Python 3.13+ (the dashboard uses only the standard library); the notch app needs macOS 26 and
Xcode 26. Installing `zstd` is optional (it reads codex's compressed history).

Where the dashboard keeps things:

- Web page: `http://127.0.0.1:8787/` (this Mac only)
- Database: `~/Library/Application Support/tokenboard/usage.db`
- Service log: `~/Library/Logs/tokenboard/<label>.log`

The dashboard's interface is in Chinese. The labels this page mentions: 今日 today, 近7日 last 7 days,
近30日 last 30 days, 模型 model, 项目 project, 设备 device, 成本 cost, 部分 partial.

## Data sources

Logs are read-only; tokenboard never changes or deletes them:

| Source | Log location | Notes |
| --- | --- | --- |
| pi | `~/.pi/agent/sessions/**/*.jsonl` | Includes `forks/`; a fork copies its parent's messages, so rows are de-duplicated by `id + timestamp` and counted once |
| claude-code | `~/.claude/projects/**/*.jsonl` | One API response is written as several lines (one per content block), de-duplicated by `message.id + requestId`; `<synthetic>` messages are skipped |
| codex | `~/.codex/sessions/**/*.jsonl[.zst]`, `~/.codex/archived_sessions/**/*.jsonl[.zst]` | Prefers `token_usage_record` (de-duplicated by `response_id`); falls back to `token_count` only for old files without it; `.zst` is read through `zstd -dc`. The ChatGPT desktop app writes here too, so its usage counts under codex |
| workbuddy | `~/.workbuddy/projects/**/*.jsonl` | Any line with `providerData.rawUsage` counts; `prompt_tokens` includes cache reads and writes, which are subtracted first; de-duplicated by `messageId + prompt/completion tokens` (two different calls with the same `messageId` both count); `tool-results/` is skipped |

Paths can be overridden with `TOKENBOARD_PI_DIR`, `TOKENBOARD_CLAUDE_DIR`, `TOKENBOARD_CODEX_DIR`,
`TOKENBOARD_WORKBUDDY_DIR`, `TOKENBOARD_DB`, `TOKENBOARD_DEVICE` and `TOKENBOARD_ALIASES`.

## Why the service has to keep running

Claude Code deletes old transcripts on its own, and pi and codex compress or clean up their history.
**The raw logs are short-lived; the database is the long-term record.** So the background service runs all
the time:

- it collects once at start-up;
- then every 300 seconds;
- it only re-reads files whose `(size, mtime)` changed;
- it writes with `INSERT OR IGNORE`, so collecting twice never counts twice;
- a file that fails to parse is logged and skipped, and retried next time, without stopping the others.

If the service is off for a few days, nothing is lost as long as the logs are still there: the next run
catches up. Usage whose logs were deleted while the service was off can't be recovered.

## Metrics

| Metric | Meaning |
| --- | --- |
| Total, cache included (总处理量) | `input + output + cache_read + cache_write` |
| Input + output (输入+输出) | `input + output`, no cache (closest to the actual compute) |
| Input only (仅输入) | `input`, input tokens that missed the cache |
| Output only (仅输出) | `output`, including reasoning tokens |
| Cost (USD) | See below; when any row's cost is unknown, the total is marked 部分 (partial) |

## Model aliases (showing several raw model names as one)

Some providers log the same model under different names (for example `deepseek-flash` and
`deepseek-v4.1-flash`), which splits it into several rows on the 模型 (model) tab.
`tokenboard/model_aliases.json` merges them into one display name **at query time**:

```json
{
  "_comment": "normalized model name -> display name used by the 模型 breakdown",
  "deepseek-flash": "deepseek-v4.1-flash:1017",
  "deepseek-v4.1-flash": "deepseek-v4.1-flash:1017"
}
```

- Keys are **normalized model names** (the part of the logged model string after the last `/`, lower-cased,
  spaces removed); values are the name shown on the model tab. Both are lower-cased and trimmed again.
- Keys starting with `_` are comments.
- Only the model tab's grouping changes: the database keeps the raw names, and cost is still looked up by the
  raw name. Hovering over a merged name lists the raw names behind it.
- Takes effect on save, without a restart; a missing or malformed file just means no aliases.
- `TOKENBOARD_ALIASES` can point to another alias file.

## Cost rules

1. **A cost written in the log wins**: pi's `usage.cost.total` is stored as is.
2. Otherwise `tokenboard/pricing.json` is used (**USD per 1M tokens**), matched by normalized model name.
   claude-code and codex go this way.
3. A model missing from the price list has an **unknown** cost. If the same group has other priced events,
   the page shows the **known subtotal** with a small 部分 (partial) mark; only a group with no known cost at
   all shows `—`. Unknown costs are left out of totals, which are then marked partial. The command line
   `summary --metric cost` follows the same rules and prints a `note: 部分（partial）…` line.
4. `cache_write` is priced at the **1-hour TTL** rate (what Claude Code writes, usually twice the input price).
5. GPT, DeepSeek and others are **not priced** out of the box, so totals usually show partial. Add your own
   prices to `pricing.json` to see full costs.

## Install (launchd background service)

```bash
scripts/install.sh
```

The script:

- finds the absolute path of `python3` and checks it is **3.13 or newer** (with a clear error if not);
- checks for `zstd` (codex's `.zst` history needs it) and warns if it's missing;
- writes a LaunchAgent to `~/Library/LaunchAgents/<label>.plist`:
  - `ProgramArguments`: `<python3> -m tokenboard serve --port <port>`
  - `WorkingDirectory`: the repository root
  - `RunAtLoad` / `KeepAlive` true, `ThrottleInterval` 30 seconds
  - output and errors go to `~/Library/Logs/tokenboard/<label>.log`
  - `PATH` is set to `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin` (launchd's default has no Homebrew,
    so `zstd` wouldn't be found), plus `PYTHONDONTWRITEBYTECODE=1`
- if the service is already running, it runs `launchctl bootout` then `launchctl bootstrap`, so it can be
  re-run safely;
- finally polls `http://127.0.0.1:<port>/api/meta` for up to 60 seconds: on success it prints the address,
  otherwise it prints the end of the log and exits non-zero.

Environment variables you can override:

| Variable | Default | Purpose |
| --- | --- | --- |
| `TB_LABEL` | `com.tokenboard.server` | LaunchAgent label (plist and log file name) |
| `TB_PORT` | `8787` | Web port (bound to 127.0.0.1 only) |
| `TOKENBOARD_DB` | `~/Library/Application Support/tokenboard/usage.db` | Database path, written into the plist when set |
| `TB_PYTHON` | `python3` on PATH | Interpreter to use |

For example, a separate instance on another port and database:

```bash
TB_LABEL=com.tokenboard.test TB_PORT=8798 TOKENBOARD_DB=/tmp/tb.db scripts/install.sh
```

## Uninstall

```bash
scripts/uninstall.sh          # or TB_LABEL=com.tokenboard.test scripts/uninstall.sh
```

It stops the service and removes `~/Library/LaunchAgents/<label>.plist`. **It deletes neither the database
nor the logs**, and prints where they are. The database is your long-term record; delete it by hand only if
you really don't need it.

## Command line

Run from the **repository root**:

```bash
cd notchbead

# collect once; prints new rows / files parsed / errors per source
python3 -m tokenboard ingest

# a day × source table (default: last 7 days, metric total)
python3 -m tokenboard summary --days 3 --metric io

# cost, by the same rules as the page (logged cost → pricing.json → unknown);
# prints a 部分（partial）note when some models have no price
python3 -m tokenboard summary --days 30 --metric cost

# run the web server in the foreground (default 8787)
python3 -m tokenboard serve --port 8787
```

`--metric` is one of `total` (default), `io`, `input`, `output`, `cost`.

Example of `summary --metric cost` (claude-code priced, codex's GPT unpriced):

```
metric: cost (USD)   range: 2026-10-03 .. 2026-11-01
       day  claude-code   codex     total
2026-11-01     181.4967  0.0000  181.4967
     TOTAL     181.4967  0.0000  181.4967
note: 部分（partial）— 812 rows in range have no known price, so the totals only
cover models listed in tokenboard/pricing.json
```

HTTP API (127.0.0.1 only):

- `GET /api/meta` → sources, devices, first and last day, last collection time
- `GET /api/daily?start=&end=&metric=` → per-day series by source (days without data are 0)
- `GET /api/breakdown?start=&end=&metric=&by=source|model|device|project` → shares
- `POST /api/ingest` → collect now; returns counts per source
- `GET /`, `GET /static/*` → the page and its assets

## Adding model prices

Edit `tokenboard/pricing.json` (USD per 1M tokens; keys are normalized model names; keys starting with `_`
are comments):

```json
{
  "_comment": "USD per 1M tokens",
  "claude-opus-5-5": {"input": 4.0, "output": 20.0, "cache_read": 0.20, "cache_write": 8.0},
  "gpt-6-astra":     {"input": 1.25, "output": 10.0, "cache_read": 0.125, "cache_write": 0.0}
}
```

No restart needed: the service checks the file on every request and reloads it. Estimated costs for past
usage update at once (the database stores tokens, not money).

Model names are normalized by taking the part after the last `/`, lower-cased, spaces removed. To see what a
model is called in the database, hover over it on the 模型 (model) tab: the raw logged names are shown.

## The notch app, NotchBead (macos/)

`macos/` holds **NotchBead**, a native Mac app (Swift, macOS 26+) that lives in the notch:

- **Things that need you**: an agent in Orca waiting for approval, hitting an error, or finishing while you were in
  another app or another Orca pane or window; a WorkBuddy session interrupted, asking you something or finished; a ChatGPT desktop
  app task finished while you weren't watching. The notch never changes size: its right wing shows today's tokens, and when
  something needs you the figure fades upward and the icon of the app that wants you (several apps take turns, each
  fading upward) and Bead, with the count on its corner, take its place; clicking the notch goes straight to the next item, most urgent first (for Orca, the exact pane), and
  items clear by themselves once handled. Each new item makes Bead hop and plays a short chime (three soft
  rising notes); untick Play Sound in the notch's right-click menu to silence it.
- **Today's tokens**: always shown, dimmed, on the right of the notch, in 亿 (100 million), such as `2.01亿`.
  It comes from the tokenboard service (`/api/breakdown`) every 15 seconds, and at once after you click 采集
  (collect now) in the dashboard window; the service itself collects every 5 minutes,
  so it can trail live use by a few minutes. Hidden when the service isn't running.
- **Dashboard window**: click the token figure, choose Open Dashboard from the right-click menu, or open
  NotchBead again from Spotlight, and the same page opens in a native window (in the Dock and Cmd-Tab while
  open).

```bash
cd macos
make install   # build, sign and copy to /Applications; then tick Open at Login in the right-click menu
make test
```

On a screen without a notch it moves to the menu bar. More in `macos/README.md`. The notch window technique
and Bead come from [onit](https://github.com/neethanwu/onit) (MIT); see `macos/LICENSE`.

## Tests

From the repository root:

```bash
python3 -m unittest discover -s tests -t .
```

The Mac app: `cd macos && make test`.

Tests use temporary folders and a temporary database (`TOKENBOARD_DB` points to a temp file); they never read
or write your real logs or database.
