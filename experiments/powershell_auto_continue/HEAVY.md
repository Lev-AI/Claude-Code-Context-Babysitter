# HEAVY reliable path (PowerShell)

**Goal:** the most **reliable** possible auto-continue on native Windows,
**without** SendKeys / UI automation.

Not "like tmux in Cursor," but:

```text
statusLine rate_limits → usage.json
        → Start-HeavyWatch (poll)
        → stop_percent (88) → soft-stop: Ctrl+C to the recorded Claude window
        → limit → wait until resets_at
        → claude -c | --resume name  +  -p "continue…"
        → retries + logs + notify
(power.prevent_sleep: hold SetThreadExecutionState so idle auto-sleep
 can't freeze the watcher/pinger/wait)
```

---

## Why this is "heavy and reliable"

| Principle | How |
|---------|-----|
| Usage signal | Official `rate_limits.five_hour` (statusLine), not OCR |
| Continue | Official CLI `claude -c` / `--resume` + `-p` |
| cwd | Explicit `-ProjectCwd` (critical for `-c`) |
| Session name | `claude -n name` → `--resume name` (more predictable) |
| Retries | 3 attempts, delay, fallback interactive window |
| State | `.state/runtime.json` + logs |
| No SendKeys | Doesn't break from Cursor's layout |

---

## Installation (one-time)

```powershell
cd ...\experiments\powershell_auto_continue
.\scripts\Install-Heavy.ps1
```

1. Paste the statusLine snippet into `%USERPROFILE%\.claude\settings.json`
   (paths with **`/`**, as in the snippet).
2. Restart Claude / make a turn — check
   `..\..\..\.session_bridge\usage.json` (5h %, `reset_at`).
3. In the project: `CLAUDE.md`, `PROGRESS.md`, Auto Mode.

---

## Daily experiment

**Window A — work:**

```powershell
cd C:\path\to\your-project
claude -n my-task
# Shift+Tab → auto
# keep PROGRESS.md updated
```

**Window B — watcher:**

```powershell
cd ...\experiments\powershell_auto_continue
Remove-Item .state\STOP -ErrorAction SilentlyContinue
.\scripts\Start-HeavyWatch.ps1 -ProjectCwd "C:\path\to\your-project" -SessionName "my-task"
```

**Stop the watcher:**

```powershell
.\scripts\Stop-HeavyWatch.ps1
```

**Manual continue (test without waiting):**

```powershell
.\scripts\Invoke-HeavyContinue.ps1 `
  -ProjectCwd "C:\path\to\your-project" `
  -SessionName "my-task" `
  -SkipWait
```

**WhatIf:**

```powershell
.\scripts\Invoke-HeavyContinue.ps1 -ProjectCwd "..." -SessionName "my-task" -WhatIf
.\scripts\Start-HeavyWatch.ps1 -Once -WhatIf
```

---

## Files

| Path | Role |
|------|------|
| `config.heavy.json` / `config.local.json` | settings |
| `lib/Common.ps1` | usage/state/log |
| `lib/Power.ps1` | prevent-sleep (`SetThreadExecutionState`) + console Ctrl+C |
| `lib/ClaudeLaunch.ps1` | headless + interactive launch |
| `scripts/Start-HeavyWatch.ps1` | main loop (soft-stop, MAINTAIN, wait+continue) |
| `scripts/Invoke-HeavyContinue.ps1` | wait + continue |
| `scripts/Install-Heavy.ps1` | setup |
| `scripts/statusline-bridge.ps1` | 5h % → usage.json |
| `.state/runtime.json` | phase, counts |
| `.state/claude_window.json` | Claude window PID recorded by `Start-Babysitter` (soft-stop target) |
| `.state/logs/YYYY-MM-DD.log` | audit trail |

---

## Limitations (honestly)

- Continue happens in a **new** process/window, not in the same Cursor
  scrollback.
- Requires the **same cwd** and, preferably, a **session name**.
- After a multi-hour wait, the context may be cold — PROGRESS is mandatory.
- On Windows, resume has occasionally frozen — there are retries + an
  interactive fallback.
- This is an **experiment**, not a replacement for WSL+auto-retry in terms
  of community maturity.

---

## When to consider it a success

1. statusLine writes `session_usage_percent` + `reset_at`.
2. The watcher, on a synthetic limit (`Register-Usage -RateLimited -ResetAt ...`),
   makes it through to continue.
3. `claude -c -p` or `--resume` actually continues the task using PROGRESS.
4. Logs in `.state/logs` are readable.
