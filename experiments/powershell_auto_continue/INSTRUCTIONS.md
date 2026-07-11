# INSTRUCTIONS — running in any project

A simple "install and use" guide. Details and internals: [README.md](./README.md), [HEAVY.md](./HEAVY.md).

**What this gives you:** you work with Claude Code in any of your projects;
while idle, the session is kept warm (the cache doesn't cool down — the next
turn is cheap), and when the 5-hour usage limit hits, the system waits for
the reset on its own and continues the same session on its own. Continuing
a warm session costs ~10% of the context price instead of the full price.

```text
statusLine → usage.json → watcher (usage limit? wait → claude --resume) 
                        → pinger  (idle 45–55 min? ping → cache stays warm)
```

---

## Installation — once, two commands

```powershell
# 1) clone (the folder can be anywhere; the examples below use C:\Tools)
git clone https://github.com/Lev-AI/Claude-Code-Context-Babysitter.git C:\Tools\Claude-Code-Context-Babysitter

# 2) install
cd C:\Tools\Claude-Code-Context-Babysitter\experiments\powershell_auto_continue
.\scripts\Install-Heavy.ps1
```

The script will:

- create the working folders and `config.local.json`;
- register `statusLine` in `%USERPROFILE%\.claude\settings.json`
  (making a backup copy; it won't touch a pre-existing statusLine — use
  `-ForceStatusLine` to replace it).

**Check:** restart Claude Code, make 1–2 turns — a line like
`Opus 4.8 | 5h 23%` will appear at the bottom. That means everything is
connected.

---

## Launch — one command from the project folder

```powershell
cd C:\path\to\your-project
& "C:\Tools\Claude-Code-Context-Babysitter\experiments\powershell_auto_continue\scripts\Start-Babysitter.ps1"
```

To launch it with a single word, add a function to your PowerShell profile
(`notepad $PROFILE`):

```powershell
function babysit { & "C:\Tools\Claude-Code-Context-Babysitter\experiments\powershell_auto_continue\scripts\Start-Babysitter.ps1" @args }
```

— after that, just run `babysit` from any project folder.

Three windows will open:

| Window | What it does |
|------|-----------|
| **Claude** | `claude -n <folder-name>` — this is where you work |
| watcher (minimized) | waits for the usage limit → continues the session on its own after the reset |
| pinger (minimized) | pings the session after a random 45–55 min of idle — keeps the cache warm |

In the Claude window: `Shift+Tab` → **Auto Mode**, and keep `PROGRESS.md`
updated (ask Claude to update it as it works).

The default session name is the project folder name. To set your own:

```powershell
& "...\scripts\Start-Babysitter.ps1" -ProjectCwd "C:\path\to\your-project" -SessionName "feature-x"
```

Useful flags: `-NoClaudeWindow` (Claude is already running — add only the
watcher+pinger), `-NoPing` (without the cache pinger), `-WhatIf` (show what
would be launched, without launching anything).

---

## Stopping — one command

```powershell
& "C:\Tools\Claude-Code-Context-Babysitter\experiments\powershell_auto_continue\scripts\Stop-HeavyWatch.ps1"
```

Stops both the watcher and the pinger (you close the Claude window
yourself). Re-running `Start-Babysitter.ps1` will remove the old STOP file
automatically — no manual cleanup needed.

---

## What happens at the limit (without you)

1. statusLine writes "100%, resets at HH:MM" to `usage.json`.
2. The watcher shows a notification and waits until the reset + 90 seconds.
3. It launches `claude --resume <name> -p "Continue… re-read PROGRESS.md…"`.
4. The session continues working; logs go to `.state\logs\YYYY-MM-DD.log`.

The pinger stays silent at the limit (the cache is already lost) — it's
useful **before** the limit and during pauses.

---

## Cost-saving rules (important)

- **Stop heavy work at ~95%** — the remaining 5% is needed for the cache
  pinger to keep the cache alive until the reset.
- **Run `/compact` at ~85%** — after the reset, the continuation will
  re-read a short history instead of a huge one.
- **Keep PROGRESS.md always up to date** — it's how the revived session
  understands what to do.
- Each ping = reading the entire context from cache (~10% of the price) —
  that's the cost of keeping it warm.

---

## If something's wrong

| Symptom | Cause / solution |
|---------|-------------------|
| No `5h NN%` in the status bar | statusLine isn't connected: run `Install-Heavy.ps1`, restart Claude. The path in settings.json must use `/` slashes |
| `usage.json` isn't updating | Same as above + check that you're making turns (the file is written after every turn) |
| The watcher doesn't see the session during continue | The session must be **named**: launch via `Start-Babysitter.ps1` or `claude -n name` |
| Continue started, but "No conversation found" | The name in `-SessionName` doesn't match the session name (`claude -n …`), or `-ProjectCwd` is different |
| The watcher exits immediately | This used to be a leftover STOP file — it's now cleaned up automatically; check `.state\logs\` |
| I want to test without hitting a real limit | `.\scripts\Register-Usage.ps1 -Percent 100 -RateLimited -ResetAt (Get-Date).AddMinutes(3).ToString("HH:mm")` and watch the watcher |

---

## Security

- statusLine executes `statusline-bridge.ps1` from your clone **after every
  turn** — only install it from a trusted source, and don't give outsiders
  write access to the clone folder.
- `Install-Heavy.ps1` modifies `settings.json` with a backup and doesn't
  touch a pre-existing statusLine.
- Don't use `--dangerously-skip-permissions`; for unattended mode, configure
  Auto Mode + deny rules (force-push, `rm -rf`, `.env`, etc.) in Claude's
  settings.
- The utility doesn't make network calls on its own — the only external
  calls are made by the `claude` CLI.

---

## Requirements

- Windows, PowerShell 5.1+ (7 preferred);
- Claude Code CLI on PATH (`claude`);
- a Pro/Max subscription (for `rate_limits` in statusLine).

The companion Python utility (`session_bridge`, not included in this
repository, optional) is **not required** for this scenario — the module
is self-contained.
