# 🍼 Claude Code Context Babysitter

![Platform](https://img.shields.io/badge/platform-Windows-0078D6?logo=windows)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)
![No WSL required](https://img.shields.io/badge/WSL-not%20required-orange)

> ⚠️ **Disclaimer — use at your own risk.** This project is a **proof-of-concept demonstrator of an engineering idea**. It has **not** been reviewed for compliance with Anthropic's Terms of Service, Usage Policies, or any other applicable agreements. Use it **entirely at your own risk** — you alone are responsible for ensuring your usage complies with Anthropic's terms.

**Unattended Claude Code sessions on native Windows.** When your Pro/Max
5-hour usage limit hits, the babysitter waits for the reset and resumes the
same session automatically. While the session idles, it keeps the prompt
cache warm — so resuming costs ~10% of the context price instead of a full
re-read.

```text
statusLine ──▶ usage.json ──▶ watcher   limit?  wait until reset ─▶ claude --resume <name> -p "continue…"
                        └───▶ pinger   idle 45–55 min? headless ping ─▶ cache stays warm (~1h TTL refreshed)
```

No WSL, no tmux, no SendKeys — only the official Claude Code CLI.

## 🚀 Quick start

```powershell
# 1) clone (any folder works; examples use C:\Tools)
git clone https://github.com/Lev-AI/Claude-Code-Context-Babysitter.git C:\Tools\Claude-Code-Context-Babysitter

# 2) install once (wires statusLine into Claude settings, with a backup)
cd C:\Tools\Claude-Code-Context-Babysitter\experiments\powershell_auto_continue
.\scripts\Install-Heavy.ps1

# 3) daily: one command from any project folder
cd C:\path\to\your-project
& "C:\Tools\Claude-Code-Context-Babysitter\experiments\powershell_auto_continue\scripts\Start-Babysitter.ps1"
```

Full guide: **[INSTRUCTIONS.md](experiments/powershell_auto_continue/INSTRUCTIONS.md)**

## 📚 Documentation

| Document | What it covers |
|----------|----------------|
| [INSTRUCTIONS.md](experiments/powershell_auto_continue/INSTRUCTIONS.md) | Step-by-step setup, daily usage, troubleshooting |
| [README.md](experiments/powershell_auto_continue/README.md) | Module overview, folder structure, all scripts |
| [HEAVY.md](experiments/powershell_auto_continue/HEAVY.md) | The full HEAVY workflow in detail |

## ⚙️ How it works

1. **statusLine bridge** — Claude Code calls `statusline-bridge.ps1` after every
   turn; it extracts `rate_limits.five_hour` (used % + exact reset time) into
   `usage.json` and renders a status bar like `Opus 4.8 | 5h 23%`.
2. **Watcher** (`Start-HeavyWatch.ps1`) — polls `usage.json`; on limit it waits
   until `resets_at` + margin, then relaunches the *same named session*:
   `claude --resume <name> -p "continue…"` (retries, logs, toast notifications).
3. **Cache pinger** (`Ping-Session.ps1`) — when the session has been idle for
   a random 45–55 minutes (seconds precision, re-drawn after every ping),
   sends a headless ACK ping that refreshes the ~1-hour prompt cache TTL.
   Measured live: a ping read 20 207 tokens from cache and wrote only 76 —
   about 7× cheaper than a cold resume.

## 📋 Requirements

- Windows, PowerShell 5.1+ (7+ recommended)
- [Claude Code CLI](https://code.claude.com/docs) on `PATH`
- Claude Pro/Max subscription (statusLine `rate_limits` payload)

## 🔒 Security notes

- The installer edits `%USERPROFILE%\.claude\settings.json` **with a timestamped
  backup** and never replaces a foreign statusLine without `-ForceStatusLine`.
- statusLine executes `statusline-bridge.ps1` from your clone after every turn —
  install from a trusted clone only.
- The tool itself makes no network calls; only the `claude` CLI does.
- Don't use `--dangerously-skip-permissions`; for unattended runs configure
  Auto Mode plus deny rules (force-push, `rm -rf`, `.env`, …).

## 🙏 Acknowledgements

- [claude-auto-retry](https://github.com/cheapestinference/claude-auto-retry) —
  inspiration for the wait-and-continue approach (tmux/Linux); this project is
  the native-Windows answer to the same problem.
- [Claude Code documentation](https://code.claude.com/docs) — statusLine and
  session management that make the reliable path possible.

## 📄 License

[MIT](LICENSE)
