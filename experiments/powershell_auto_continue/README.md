# PowerShell Auto-Continue — Experiment

A standalone experiment within **Claude Code Session Bridge**.

| | |
|--|--|
| **Where** | `experiments/powershell_auto_continue/` |
| **Why** | Auto-continue after the 5-hour usage limit on **native Windows / PowerShell**, without WSL or tmux |
| **Status** | Experimental · optional module |
| **Primary experiment path** | **HEAVY** (watcher + wait + `claude -c` / `--resume` + `-p`) |

See also: the repository root README.

> **Quick start in any project: [INSTRUCTIONS.md](./INSTRUCTIONS.md)** — one-command install (`Install-Heavy.ps1`), one-command launch (`Start-Babysitter.ps1`).

---

## The idea in plain terms

Claude in Cursor (PowerShell) hits the PRO usage limit.

The experiment:

1. Finds out the usage / reset time (preferably via **statusLine**).
2. Waits for the reset.
3. Launches a **new** Claude with continue (`claude -c` or `--resume name` + `-p "..."`).

This is **not** keystroke injection into the same Cursor window (too fragile).
This is a **reliable relaunch** via the official CLI.

```text
statusLine → usage.json
     → Start-HeavyWatch
     → limit?  wait until resets_at
     → claude -c | --resume  +  -p "Continue… PROGRESS…"
     → logs + notify + retries
```

---

## Two levels in this folder

| Level | What | Commands |
|---------|-----|---------|
| **HEAVY** (recommended) | Full cycle: install, statusLine, watch, continue | `Install-Heavy.ps1`, `Start-HeavyWatch.ps1` |
| **Light** | Separate E1 toast / E2 wait scripts | `Notify-Limit.ps1`, `Wait-And-Continue.ps1` |

Details on HEAVY: **[HEAVY.md](./HEAVY.md)**

---

## Folder structure

```text
powershell_auto_continue/
├── README.md                 ← this file
├── HEAVY.md                  ← heavy-path guide
├── config.heavy.json         ← heavy config
├── config.example.json       ← light example
├── lib/
│   ├── Common.ps1            ← usage, state, log, notify
│   ├── Power.ps1             ← prevent-sleep + console Ctrl+C (Win32)
│   └── ClaudeLaunch.ps1      ← headless + interactive launch
├── scripts/
│   ├── Install-Heavy.ps1     ← setup + statusLine snippet
│   ├── Start-HeavyWatch.ps1  ← main watcher
│   ├── Stop-HeavyWatch.ps1
│   ├── Ping-Session.ps1      ← keepalive: headless --resume ping (cache pinger)
│   ├── Invoke-HeavyContinue.ps1
│   ├── statusline-bridge.ps1 ← 5h % + reset_at → usage.json
│   ├── Register-Usage.ps1    ← manual usage entry
│   ├── Notify-Limit.ps1      ← light E1
│   └── Wait-And-Continue.ps1 ← light E2
├── samples/
│   └── limit_message.txt
└── .state/                   ← runtime + logs (gitignored)
```

---

## Quick start (HEAVY)

### 1. One-time — install

```powershell
cd C:\Tools\Claude-Code-Context-Babysitter\experiments\powershell_auto_continue

.\scripts\Install-Heavy.ps1
```

Next:

1. Open `%USERPROFILE%\.claude\settings.json`.
2. Paste the snippet from the install output (or from `.state\settings-snippet.txt`).
3. The path to `statusline-bridge.ps1` must use **forward slashes `/`**, not `\`.
4. In the project: `PROGRESS.md`, optionally `CLAUDE.md`.
5. Claude: **Auto Mode** (`Shift+Tab`).

Check: after 1–2 turns in Claude, the file
`..\..\..\.session_bridge\usage.json` should be updating (5h %, `reset_at`).

### 2. Working

**Window A — Claude:**

```powershell
cd C:\path\to\your-project
claude -n my-task
# Shift+Tab → auto
# keep PROGRESS.md updated
```

**Window B — watcher:**

```powershell
cd C:\Tools\Claude-Code-Context-Babysitter\experiments\powershell_auto_continue

.\scripts\Start-HeavyWatch.ps1 `
  -ProjectCwd "C:\path\to\your-project" `
  -SessionName "my-task"
```

(a stale `.state\STOP` is removed automatically on start)

### 3. Stop the watcher

```powershell
.\scripts\Stop-HeavyWatch.ps1
# or: New-Item .state\STOP -ItemType File
```

### 3.5 Cache pinger (optional, window C)

While the session is idle (lunch, evening before the limit resets), this keeps
its prompt cache warm with a headless ping of the same session — after the
reset, continuing costs ~10% of the context price (cache read) instead of a
full rewrite:

```powershell
.\scripts\Ping-Session.ps1 `
  -ProjectCwd "C:\path\to\your-project" `
  -SessionName "my-task"
```

Pings when the session history hasn't changed for a random interval between
`ping_idle_min_minutes` and `ping_idle_max_minutes` (45–55 min, seconds
precision, re-drawn after every ping); stays silent when rate_limited (the
cache is already lost — that's
the watcher's job). Stop with the same `.state\STOP`. One-off ping: `-Once -Force`.

### 4. Manual continue (test)

```powershell
.\scripts\Invoke-HeavyContinue.ps1 `
  -ProjectCwd "C:\path\to\your-project" `
  -SessionName "my-task" `
  -SkipWait

# without actually launching:
.\scripts\Invoke-HeavyContinue.ps1 -ProjectCwd "..." -SessionName "my-task" -WhatIf
```

---

## Light scripts (no watcher)

```powershell
# Record "limit until 17:00"
.\scripts\Register-Usage.ps1 -Percent 100 -RateLimited -ResetAt "17:00"

# Notification only (E1)
.\scripts\Notify-Limit.ps1 -ResetAt "17:00" -NoBeep

# Wait + simple relaunch (E2 light)
.\scripts\Wait-And-Continue.ps1 -ResetAt "17:00" -WhatIf
```

---

## Configuration

| File | Purpose |
|------|------------|
| `config.heavy.json` | Heavy template |
| `config.local.json` | Your overrides (created by Install; **not in git**) |

Important fields in `config.heavy.json`:

- `project_cwd` / `session_name` — can be set in the config or via the CLI
- `thresholds.stop_percent` (88), `maintain_percent` (95), `limit_percent` (99.5)
- `stop.enabled` — soft-stop: at `stop_percent` the watcher sends Ctrl+C to the
  interactive Claude window started by `Start-Babysitter` (only that recorded
  PID), so the last percent isn't burned mid-turn
- `power.prevent_sleep` — hold `SetThreadExecutionState` while watcher/pinger
  run, so Windows idle auto-sleep can't freeze them (off by default; enable
  for unattended/overnight runs on AC)
- `keepalive.messages` + `message_pick` — pool of keepalive texts
  (`random_no_repeat` by default) so pings don't repeat the same message
- `continue.mode`: `headless` \| `interactive` \| `both`
- `wait.margin_seconds` (buffer after reset)

---

## What counts as success

1. statusLine writes `session_usage_percent` and `reset_at`.
2. The watcher sees the limit (real or via `Register-Usage`).
3. After the wait, `claude` starts with continue / PROGRESS.
4. Logs are present in `.state\logs\`.

---

## Limitations (honestly)

| Have | Don't have |
|------|-----|
| Wait + auto relaunch via CLI | Continue **in the same** Cursor pane |
| statusLine 5h % | 100% parity with WSL + claude-auto-retry |
| Retries, logs, notify | Stable SendKeys |
| Named sessions | Official Anthropic support |

Cold-resuming a long session after hours of waiting can **expensively** eat
into the new context window — keep **PROGRESS.md** updated and run `/compact`
before the limit.

---

## Requirements

- Windows
- PowerShell 5.1+ (7+ preferred)
- Claude Code CLI on PATH (`claude`)
- Recommended: Git for Windows (for statusLine on Windows)
- Optional: a venv with the companion Python utility (`session_bridge`, not
  included in this repository, optional) for `resume` integration

---

## Documents in this experiment

| File | Contents |
|------|------------|
| [README.md](./README.md) | Overview (you are here) |
| [HEAVY.md](./HEAVY.md) | Detailed heavy workflow |

---

## Security

- Auto Mode + deny rules in Claude.
- Don't use `--dangerously-skip-permissions` "forever".
- This experiment does not touch the companion Python utility's production
  defaults (`dry_run`).
- Don't run someone else's Claude `install.ps1` — only from **claude.ai**.
