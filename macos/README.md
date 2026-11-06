# NotchBead

Shows what your agents are waiting on you for, in the notch (or the menu bar on a screen without one), today's token use from tokenboard, the dashboard in the rest of this repository, and, when nothing needs you, your own scheduled tasks.

- **Orca**: an agent stopped for your approval or a reply, hit an error, or finished while you were somewhere else: another app, or another Orca pane or window (Orca has no way to say where you are, so the pane you last sent something in counts as the one you are looking at). Workers started by another agent are left to that agent.
- **WorkBuddy**: a session was interrupted or failed, stopped to ask you something, or finished while WorkBuddy wasn't in front.
- **ChatGPT** (the desktop app, which is OpenAI's Codex app): a task or an ordinary chat reply finished while ChatGPT wasn't in front. Stopping a task yourself doesn't count, and Codex CLI runs are left to Orca.

Each item goes away by itself once it's handled: you switch to that Orca project, the agent carries on, or the WorkBuddy session runs again (a normal finish also clears when you switch to WorkBuddy; a ChatGPT task clears when you switch to ChatGPT or start another turn). Clicking the notch goes straight to the next item (for Orca, the exact pane), most urgent first: waiting on you, then errors, then finished. Click again for the one after; once every item has had a turn it starts over.

The notch never changes size: a small wing is always out on each side. The right one shows today's token use in 亿 (10^8), dimmed, such as `2.01亿`. When something needs you, the left one fills with the icon of the app that wants you and Bead, onit's mascot, blue and following your pointer, with a small count of how many on its top-right corner that moves with it. When several apps want you, their icons take turns, each drifting up and fading out as the next rises in. Bead hops and a short chime plays (three soft rising pips) when something new arrives; turn it off with Play Sound in the right-click menu. Click the token figure, choose Open Dashboard from the notch's right-click menu, or open NotchBead again from Spotlight to see tokenboard's page in a window of its own. Right-click the notch also has Play Sound, Open at Login and Quit.

## What it reads

| Source | How |
| --- | --- |
| Orca | `orca worktree ps --json` and `orca terminal list --json`, with the CLI inside Orca.app. Only names and states are decoded, never prompts, commands or replies |
| WorkBuddy | `~/.workbuddy/workbuddy.db`, opened read-only (`mode=ro`): session title and status, compared from one poll to the next |
| ChatGPT | `~/.codex/state_5.sqlite`, opened read-only: desktop-app thread names and log paths. Then only the end of each changed thread's log, for the last `task_started` / `task_complete` / `turn_aborted` line; message text is skipped unread. For ordinary chats, `~/.codex/sqlite/codex.db` (read-only): the ids of chats with a reply in progress (`active_chat_turns`) and their titles |

| tokenboard | `GET http://127.0.0.1:8787/api/breakdown` for today, every 15 seconds, on each arrival, and right after 采集 (collect now) in the dashboard window; the dashboard window loads the same address. Point it elsewhere with `defaults write io.github.successcw.notchbead tokenboardURL http://127.0.0.1:<port>` |

## Your scheduled tasks

When nothing needs you, Bead dozes in the left wing, grey. Click it (or choose Scheduled Tasks from the right-click menu) and the notch opens into the scheduled-tasks panel from onit: your own tasks, what each runs on, when it runs next, whether the last run worked, and why it failed if it didn't. Bead shows how they're doing: dozing when all is well, running while one runs, amber when a schedule needs a look, red when one failed. Click a task for its detail: schedule in words, next run, recent runs, the end of its log, and actions. Escape or a click elsewhere closes the panel.

Only tasks you set up yourself, or had an agent set up, are listed:

- launchd agents in `~/Library/LaunchAgents` whose program, script or working folder is in your home folder (outside `~/Library` and hidden folders), or that are named after you (`com.<your user name>.…`). Agents that apps install, such as updaters, are left out.
- Every entry in your own crontab.
- Codex automations (`~/.codex/automations/*/automation.toml`) and WorkBuddy automations (its database, read-only): names, status and schedules only, never the prompts.

Actions: Run Now (`launchctl kickstart`, or a crontab entry run exactly as cron would), Pause and Resume (`launchctl disable`/`bootout` and `enable`/`bootstrap`, on your own agents only), open the log in Console, show the plist in Finder, copy the command, and Copy for your agent, a fix prompt with keys and tokens masked. Codex and WorkBuddy automations are changed in their apps; the detail has a button to open them. NotchBead never edits plists or your crontab.

NotchBead records each run it sees in `~/Library/Application Support/NotchBead/history.json` (the last 50 per task), since launchd keeps no history.

NotchBead connects to nothing but tokenboard on this Mac, and writes nothing but its own settings and that run history.

## Build

```bash
make run       # build, bundle, sign ad hoc and open NotchBead.app
make install   # copy to /Applications and open it (use this before turning on Open at Login)
make test
make icon      # redraw the white app icon
make sound     # rewrite the arrival chime from SupportFiles/generate-sound.py
```

To see the notch without waiting on an agent: `open --env NOTCHBEAD_DEMO=1 NotchBead.app` adds a sample item after a few seconds; `open --env NOTCHBEAD_OPEN=1 NotchBead.app` opens the scheduled-tasks panel at launch.

Needs macOS 26 and Xcode 26 (Swift 6.2). The notch window technique is adapted from [onit](https://github.com/neethanwu/onit) (MIT).
