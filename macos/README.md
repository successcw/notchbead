# Heed

Shows what your agents are waiting on you for, in the notch (or the menu bar on a screen without one), and today's token use from tokenboard, the dashboard in the rest of this repository.

- **Orca**: an agent stopped for your approval or a reply, hit an error, or finished in a project you aren't looking at.
- **WorkBuddy**: a session was interrupted or failed, stopped to ask you something, or finished while WorkBuddy wasn't in front.
- **ChatGPT** (the desktop app, which is OpenAI's Codex app): a task finished while ChatGPT wasn't in front. Stopping a task yourself doesn't count, and Codex CLI runs are left to Orca.

Each item goes away by itself once it's handled: you switch to that Orca project, the agent carries on, or the WorkBuddy session runs again (a normal finish also clears when you switch to WorkBuddy; a ChatGPT task clears when you switch to ChatGPT or start another turn). Clicking the notch goes straight to the next item (for Orca, the exact pane), most urgent first: waiting on you, then errors, then finished. Click again for the one after; once every item has had a turn it starts over.

The right of the notch always shows today's token use in 亿 (10^8), dimmed, such as `2.01亿`. When something needs you, Bead, onit's mascot, also comes out on the left of the notch, blue, running and following your pointer, with a small count of how many on its top-right corner that moves with it. Bead hops when something new arrives. Click the token figure, choose Open Dashboard from the notch's right-click menu, or open Heed again from Spotlight to see tokenboard's page in a window of its own. Right-click the notch also has Open at Login and Quit.

## What it reads

| Source | How |
| --- | --- |
| Orca | `orca worktree ps --json` and `orca terminal list --json`, with the CLI inside Orca.app. Only names and states are decoded, never prompts, commands or replies |
| WorkBuddy | `~/.workbuddy/workbuddy.db`, opened read-only (`mode=ro`): session title and status, compared from one poll to the next |
| ChatGPT | `~/.codex/state_5.sqlite`, opened read-only: desktop-app thread names and log paths. Then only the end of each changed thread's log, for the last `task_started` / `task_complete` / `turn_aborted` line; message text is skipped unread |

| tokenboard | `GET http://127.0.0.1:8787/api/breakdown` for today, every minute and on each arrival; the dashboard window loads the same address. Point it elsewhere with `defaults write io.github.successcw.heed tokenboardURL http://127.0.0.1:<port>` |

Heed connects to nothing but tokenboard on this Mac, and writes nothing but its own settings.

## Build

```bash
make run       # build, bundle, sign ad hoc and open Heed.app
make install   # copy to /Applications and open it (use this before turning on Open at Login)
make test
make icon      # redraw the white app icon
```

To see the notch without waiting on an agent: `open --env HEED_DEMO=1 Heed.app` adds a sample item after a few seconds.

Needs macOS 26 and Xcode 26 (Swift 6.2). The notch window technique is adapted from [onit](https://github.com/neethanwu/onit) (MIT).
