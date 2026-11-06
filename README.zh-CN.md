<p align="center"><img src="docs/media/promo-zh.gif" alt="NotchBead 演示：Bead 从刘海里跳出来提醒你，点 token 数打开用量看板" width="100%"></p>

<p align="center"><a href="README.md">English</a> · <b>简体中文</b></p>

<p align="center"><sub>演示用的是虚构数据。<a href="docs/media/promo-zh.mp4">高清视频（带声音）</a> · <a href="docs/media/dashboard.png">看板截图</a></sub></p>

# NotchBead

住在 Mac 刘海里的 AI 编程助手管家，外加一个本地 token 用量看板。

- **刘海提醒**：Orca 里的 agent 等你确认、出错或做完，WorkBuddy 会话中断，ChatGPT 桌面版的任务或对话回复完成，
  蓝色的 Bead 就会从刘海里跳出来，带一声短促的提示音；点一下直接跳到那个窗口。
- **今日用量常驻**：刘海右侧一直显示今天用了多少 token（比如 `2.01亿`）。
- **用量看板（tokenboard）**：把 **pi**、**claude-code**、**codex**（含 ChatGPT 桌面版）、**workbuddy**
  写在本地日志里的用量汇总进 SQLite，按天、按 Agent、按模型、按项目画出来，成本一起算。
- **全部在本机**：日志只读，只监听 `127.0.0.1`，不上传、不联网。MIT 开源。

## 快速开始

```bash
git clone https://github.com/successcw/notchbead.git
cd notchbead
scripts/install.sh          # 用量看板，常驻服务：http://127.0.0.1:8787/
cd macos && make install    # 刘海小程序，装到 /Applications
```

需要 macOS、Python 3.13+（看板只用标准库）；刘海小程序需要 macOS 26 和 Xcode 26。
可选安装 `zstd`（读取 codex 的压缩历史）。

看板的位置：

- 网页：`http://127.0.0.1:8787/`（仅本机可访问）
- 数据库：`~/Library/Application Support/tokenboard/usage.db`
- 服务日志：`~/Library/Logs/tokenboard/<label>.log`

## 数据来源

日志只读，tokenboard 从不修改或删除这些文件：

| 来源 | 日志位置 | 说明 |
| --- | --- | --- |
| pi | `~/.pi/agent/sessions/**/*.jsonl` | 含 `forks/` 子目录；fork 会复制父会话的消息，按 `id + timestamp` 去重，只算一次 |
| claude-code | `~/.claude/projects/**/*.jsonl` | 一个 API 响应会写成多行（每个 content block 一行），按 `message.id + requestId` 去重；`<synthetic>` 消息跳过 |
| codex | `~/.codex/sessions/**/*.jsonl[.zst]`、`~/.codex/archived_sessions/**/*.jsonl[.zst]` | 优先 `token_usage_record`（按 `response_id` 去重）；老文件没有该记录时才回退到 `token_count`；`.zst` 通过 `zstd -dc` 解压 |
| workbuddy | `~/.workbuddy/projects/**/*.jsonl` | 任何带 `providerData.rawUsage` 的行都算用量；`prompt_tokens` 含缓存读写，会先扣掉 `cache_read`/`cache_write`；按 `messageId + prompt/completion tokens` 去重（同一个 `messageId` 的两次不同调用都算）；`tool-results/` 目录跳过 |

可用环境变量覆盖路径：`TOKENBOARD_PI_DIR`、`TOKENBOARD_CLAUDE_DIR`、
`TOKENBOARD_CODEX_DIR`、`TOKENBOARD_WORKBUDDY_DIR`、`TOKENBOARD_DB`、
`TOKENBOARD_DEVICE`、`TOKENBOARD_ALIASES`。

## 为什么服务必须常驻

Claude Code 会自动删除旧的 transcript，pi / codex 也会压缩或清理历史日志。
**原始日志是短期的，数据库才是长期记录。** 所以后台服务需要一直运行：

- 启动时立刻采集一次；
- 之后每 300 秒采集一次；
- 只重新解析 `(size, mtime)` 变化的文件；
- 写入用 `INSERT OR IGNORE`，重复采集永远不会重复计数（幂等）；
- 某个文件解析失败只会记录错误并跳过，下次运行会重试，不会中断其它文件。

如果服务停了几天，那几天的历史不会丢（日志还在时下次采集会补上）；
但如果日志在服务停摆期间被工具删掉，那段用量就无法恢复。

## 指标定义

| 指标 | 含义 |
| --- | --- |
| 总处理量（含 cache） | `input + output + cache_read + cache_write`，包含缓存命中与写入 |
| 输入+输出 | `input + output`，不含缓存（最接近"实际计算量"） |
| 仅输入 | `input`，未命中缓存的输入 token |
| 仅输出 | `output`，包含推理（reasoning）token |
| 成本 (USD) | 见下节；有任一记录成本未知时，总计标注为「部分」 |

## 模型别名（把多个原始模型名合并显示）

有些上游会用不同的名字记录同一个模型（例如 `deepseek-flash` 和
`deepseek-v4.1-flash`），「模型」标签页里就会拆成几行。用
`tokenboard/model_aliases.json` 可以在**查询时**把它们合并成一个显示名：

```json
{
  "_comment": "normalized model name -> display name used by the 模型 breakdown",
  "deepseek-flash": "deepseek-v4.1-flash:1017",
  "deepseek-v4.1-flash": "deepseek-v4.1-flash:1017"
}
```

- 键是**归一化后的模型名**（取日志里模型字符串最后一个 `/` 之后、小写、去空格），
  值是合并后在「模型」标签页显示的名字；键和值都会再统一转小写、去空格。
- 以 `_` 开头的键是注释，会被忽略。
- 只影响「模型」标签页的分组：数据库里存的原始模型名不变，成本计算也仍按原始模型名查价。
  鼠标停在合并后的名字上，会列出它背后的所有原始模型名。
- 保存即生效，不需要重启服务；文件缺失或格式错误就当作「没有别名」，不会报错。
- 环境变量 `TOKENBOARD_ALIASES` 可以指向另一份别名文件。

## 成本规则

1. **日志里自带成本时优先用日志**：pi 的 `usage.cost.total` 直接入库。
2. 否则查 `tokenboard/pricing.json`（单位：**美元 / 100 万 token**），按归一化后的
   模型名匹配（取最后一个 `/` 之后、小写）。claude-code 与 codex 走这条路。
3. 模型不在价格表里 → 该行事件的成本**未知**：同一分组里如果还有已定价（或日志自带成本）
   的事件，网页照常显示**已知小计**并加一个小标记「部分」；只有当整个分组都没有已知成本时
   才显示 `—`。未知成本不计入合计，合计因此会标记「部分”；命令行 `summary --metric cost`
   同样按这套规则计算，并在表下打印 `note: 部分（partial）…` 提醒。
4. `cache_write` 按 **1 小时 TTL** 的价格计价（Claude Code 写缓存用的是这个档位，
   通常是 input 单价的 2 倍）。
5. GPT / DeepSeek 等模型目前**未定价**（价格表里没有它们），所以成本合计通常显示
   「部分」；想看到完整成本，把自己的价格加进 `pricing.json` 即可。

## 安装（launchd 常驻服务）

```bash
scripts/install.sh
```

脚本会做这些事：

- 解析当前 `python3` 的绝对路径，并检查版本 **≥ 3.13**（不满足会给出明确报错）；
- 检查 `zstd` 是否可用（codex 的 `.zst` 历史需要它），缺失时给出警告；
- 在 `~/Library/LaunchAgents/<label>.plist` 写入 LaunchAgent：
  - `ProgramArguments`：`<python3> -m tokenboard serve --port <port>`
  - `WorkingDirectory`：仓库根目录
  - `RunAtLoad` / `KeepAlive` 为 true，`ThrottleInterval` 30 秒
  - 输出与错误都写到 `~/Library/Logs/tokenboard/<label>.log`
  - `PATH` 固定为 `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`
    （launchd 默认 PATH 不含 Homebrew，否则找不到 `zstd`），
    并设置 `PYTHONDONTWRITEBYTECODE=1`
- 如果同名服务已在运行，先 `launchctl bootout` 再 `launchctl bootstrap`，可反复执行；
- 最后轮询 `http://127.0.0.1:<port>/api/meta` 最多 60 秒：成功打印访问地址，
  失败则打印日志尾部并以非零状态退出。

可覆盖的环境变量：

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `TB_LABEL` | `com.tokenboard.server` | LaunchAgent 标签（plist 与日志文件名） |
| `TB_PORT` | `8787` | 网页端口（只绑定 127.0.0.1） |
| `TOKENBOARD_DB` | `~/Library/Application Support/tokenboard/usage.db` | 数据库路径，设置后会写进 plist |
| `TB_PYTHON` | PATH 上的 `python3` | 指定解释器 |

例：换端口和数据库跑一份独立实例

```bash
TB_LABEL=com.tokenboard.test TB_PORT=8798 TOKENBOARD_DB=/tmp/tb.db scripts/install.sh
```

## 卸载

```bash
scripts/uninstall.sh          # 或 TB_LABEL=com.tokenboard.test scripts/uninstall.sh
```

只做两件事：停止服务、删除 `~/Library/LaunchAgents/<label>.plist`。
**不会删除数据库，也不会删除日志**，脚本最后会打印它们的位置。
数据库是长期记录，确实不需要时请手动删除。

## 命令行用法

在**仓库根目录**执行（clone 下来的 notchbead 目录）：

```bash
cd <仓库目录>

# 采集一次，打印每个来源的新增行数 / 解析文件数 / 错误数
python3 -m tokenboard ingest

# 按天 × 来源打印表格（默认近 7 天，指标 total）
python3 -m tokenboard summary --days 3 --metric io

# 成本：与网页同一套规则（日志成本 → pricing.json 估算 → 未知），
# 有未定价模型时会在表下打印一行「部分（partial）」提示
python3 -m tokenboard summary --days 30 --metric cost

# 前台启动网页服务（默认 8787）
python3 -m tokenboard serve --port 8787
```

`--metric` 可选：`total`（默认）、`io`、`input`、`output`、`cost`。

`summary --metric cost` 的输出示例（claude-code 有价格、codex 的 GPT 未定价）：

```
metric: cost (USD)   range: 2026-10-03 .. 2026-11-01
       day  claude-code   codex     total
2026-11-01     181.4967  0.0000  181.4967
     TOTAL     181.4967  0.0000  181.4967
note: 部分（partial）— 812 rows in range have no known price, so the totals only
cover models listed in tokenboard/pricing.json
```

也就是说：有价格的模型照常计入，未定价模型的行的成本按「未知」处理（不计入合计），
并在末尾用 `note: 部分（partial）` 提醒合计只覆盖已知价格部分。

HTTP 接口（仅 127.0.0.1）：

- `GET /api/meta` → 来源、设备、首末日期、最近采集时间
- `GET /api/daily?start=&end=&metric=` → 每天的按来源序列（区间内无数据的日子补 0）
- `GET /api/breakdown?start=&end=&metric=&by=source|model|device|project` → 占比明细
- `POST /api/ingest` → 立即采集，返回各来源计数
- `GET /`、`GET /static/*` → 网页与静态资源

## 如何新增模型价格

编辑 `tokenboard/pricing.json`（单位：美元 / 100 万 token，键是归一化模型名，
以 `_` 开头的键是注释，会被忽略）：

```json
{
  "_comment": "USD per 1M tokens",
  "claude-opus-5-5": {"input": 4.0, "output": 20.0, "cache_read": 0.20, "cache_write": 8.0},
  "gpt-6-astra":     {"input": 1.25, "output": 10.0, "cache_read": 0.125, "cache_write": 0.0}
}
```

保存后无需重启：服务每次请求都会检查文件是否变动，自动重新加载。
历史记录的估算成本会立即随之更新（数据库里存的是 token 数，不是金额）。

模型名的归一化规则：取日志里模型字符串最后一个 `/` 之后的部分，转小写并去空格。
不确定某个模型在库里叫什么，可以在网页「模型」标签页把鼠标停在该名字上，
会显示日志中的原始模型名。

## 刘海小程序 NotchBead（macos/）

`macos/` 里是原生 Mac 小程序 **NotchBead**（Swift，macOS 26+），住在刘海里：

- **需要你处理的事**：Orca 里有 agent 等你审批、报错，或者在你没看着时完成（你在别的应用，或在 Orca 的另一个 pane、另一个窗口）；
  WorkBuddy 会话中断、等你回答或完成；ChatGPT 桌面版（即 Codex 应用）的任务或普通对话回复在你没看着时完成。
  刘海两侧固定各伸出一小段，形状始终不变：右侧常驻今天的 token 数；有事时左侧出现弹出提醒的应用图标（多个应用时轮流显示，向上淡出切换）和蓝色 Bead，Bead 右上角挂着待处理数量；点一下刘海按顺序直接跳到下一件
  （Orca 会切到那个 pane），处理完自动消失。新提醒到来时 Bead 跳一下，并响一声很短的
  提示音（三个柔和的上行音）；右键刘海取消勾选 Play Sound 可以关掉。
- **你的定时任务**（来自 onit）：没有需要处理的事时，左侧是一个打盹的灰色 Bead，点一下展开定时任务面板，
  只列出你自己（或让 Codex、WorkBuddy）建的任务：程序、脚本或工作目录在主目录里的 launchd 任务、你的 crontab、
  Codex 和 WorkBuddy 的自动化任务。每项显示计划、下次运行、上次结果和失败原因，可以立即运行、暂停和恢复。
  有任务失败时 Bead 变红。
- **今日 token 用量**：刘海右侧常驻显示，颜色偏暗，单位固定为「亿」，比如 `2.01亿`。
  数字来自本机 tokenboard 服务（`/api/breakdown`），每 15 秒刷新一次，在看板窗口点「立即采集」后立刻刷新；服务每 5 分钟采集一次，
  所以会比实时略晚几分钟。服务没运行时不显示。
- **token 面板**：点刘海右侧的 token 数，刘海直接展开：今日总量和费用、近 7 天按 Agent 堆叠的柱状图、今日按 Agent 或按模型的占比，
  还有「采集」按钮和打开完整看板的按钮。
- **看板窗口**：在 token 面板里点打开按钮、右键刘海选 Open Dashboard，或者在 Spotlight 里再次打开 NotchBead，
  会用独立的原生窗口打开同一个网页（出现在 Dock 和 Cmd-Tab 里，关掉就回到只有刘海）。

```bash
cd macos
make install   # 编译、签名并装到 /Applications，然后右键刘海勾选 Open at Login
make test
```

没有刘海的屏幕上它会退到菜单栏。详见 `macos/README.md`。
刘海窗口的做法改编自 [onit](https://github.com/neethanwu/onit)（MIT），许可见 `macos/LICENSE`。

## 跑测试

在仓库根目录执行：

```bash
python3 -m unittest discover -s tests -t .
```

Mac 程序的测试：`cd macos && make test`。

测试全部使用临时目录和临时数据库（`TOKENBOARD_DB` 指向临时文件），
不会读写你自己的真实日志与数据库。
