#Requires -Version 5.1
<#
.SYNOPSIS
  Keepalive pinger: keeps a named Claude session's prompt cache warm via headless --resume pings.

.DESCRIPTION
  While the session is idle (its history file unchanged for ping_after_idle_minutes)
  and not rate-limited, sends:

      claude --resume <SessionName> -p "<ACK message>"

  Each ping re-reads the session context as a cache READ (~10% of full price) and
  refreshes the ~1h cache TTL, so after a limit reset the session continues warm
  instead of paying full cache-write for the whole context.

  Companion to Start-HeavyWatch.ps1 (which handles limit wait + continue).
  Shares the same .state\STOP file: Stop-HeavyWatch.ps1 stops both.

.EXAMPLE
  .\Ping-Session.ps1 -ProjectCwd "C:\work\app" -SessionName "my-task"
  .\Ping-Session.ps1 -ProjectCwd "C:\work\app" -SessionName "my-task" -Once -Force
  .\Ping-Session.ps1 -ProjectCwd "C:\work\app" -SessionName "my-task" -WhatIf
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = "",
    [string] $ProjectCwd = "",
    [string] $SessionName = "",
    [switch] $Once,
    [switch] $Force,
    [switch] $WhatIf
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\lib\Common.ps1")

$cfg = Read-HeavyConfig -ConfigPath $ConfigPath
$ka = Get-Prop $cfg "keepalive"
$enabled = [bool](Get-Prop $ka "enabled" $true)
$idleMin = [double](Get-Prop $ka "ping_after_idle_minutes" 50)
$pollSec = [int](Get-Prop $ka "poll_seconds" 60)
$msg = [string](Get-Prop $ka "message" "ACK only: context keep-alive. Do not run tools. Reply with OK.")
$maxStreak = [int](Get-Prop $ka "max_consecutive_pings" 8)
$claude = [string](Get-Prop (Get-Prop $cfg "continue") "claude_command" "claude")

$usageFile = [System.IO.Path]::GetFullPath((Join-Path (Get-ExperimentRoot) (
    [string](Get-Prop $cfg "usage_file" "../../.session_bridge/usage.json")
)))

if (-not $ProjectCwd) { $ProjectCwd = [string](Get-Prop $cfg "project_cwd" "") }
if (-not $ProjectCwd) { $ProjectCwd = (Get-Location).Path }
if (-not $SessionName) { $SessionName = [string](Get-Prop $cfg "session_name" "") }
if (-not $SessionName) { throw "SessionName required (pass -SessionName or set session_name in config)" }
if (-not (Test-Path $ProjectCwd)) { throw "Project cwd does not exist: $ProjectCwd" }
if (-not $enabled) { Write-BridgeLog "keepalive.enabled=false in config - nothing to do" "WARN"; return }
if (-not (Test-ClaudeAvailable -ClaudeCommand $claude)) { throw "Claude command not on PATH: $claude" }

function Get-SessionLastActivity {
    param([string] $Cwd)
    # Claude Code stores session history under ~/.claude/projects/<munged cwd>/*.jsonl
    $munged = ($Cwd -replace '[^A-Za-z0-9]', '-')
    $dir = Join-Path $env:USERPROFILE ".claude\projects\$munged"
    if (-not (Test-Path $dir)) { return $null }
    $newest = Get-ChildItem $dir -Filter *.jsonl -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { return $null }
    return $newest.LastWriteTime
}

function Invoke-SessionPing {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        Push-Location -LiteralPath $ProjectCwd
        $out = "" | & $claude --resume $SessionName -p $msg --output-format json 2>&1 | Out-String
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
        $ErrorActionPreference = $old
    }
    if ($code -ne 0) {
        Write-BridgeLog "PING failed exit=$code :: $($out.Trim())" "WARN"
        return $false
    }
    $j = $null
    $idx = $out.IndexOf('{')
    if ($idx -ge 0) {
        try { $j = $out.Substring($idx) | ConvertFrom-Json } catch { }
    }
    if ($j) {
        $u = Get-Prop $j "usage"
        Write-BridgeLog ("PING ok: cache_read={0} cache_write={1} out={2} cost_usd={3}" -f `
            (Get-Prop $u "cache_read_input_tokens" "?"), `
            (Get-Prop $u "cache_creation_input_tokens" "?"), `
            (Get-Prop $u "output_tokens" "?"), `
            (Get-Prop $j "total_cost_usd" "?"))
    }
    else {
        Write-BridgeLog "PING ok (result json not parsed)"
    }
    return $true
}

$stopFile = Join-Path (Get-ExperimentRoot) ".state\STOP"
if (-not $Once -and (Test-Path $stopFile)) {
    Remove-Item $stopFile -Force -ErrorAction SilentlyContinue
    Write-BridgeLog "Removed stale STOP file on startup"
}
$lastPingAt = $null
$pingStreak = 0

Write-BridgeLog "PING watch start cwd=$ProjectCwd session=$SessionName idle>=$($idleMin)m poll=${pollSec}s usageFile=$usageFile"
if (-not $Once) { Write-Host "Stop: create $stopFile  or Ctrl+C" }

while ($true) {
    if (Test-Path $stopFile) {
        Write-BridgeLog "STOP file present - exiting ping watch"
        break
    }

    $snap = Get-UsageSnapshot -UsageFile $usageFile
    $activity = Get-SessionLastActivity -Cwd $ProjectCwd

    # User (or watcher continue) touched the session after our last ping -> reset streak
    if ($lastPingAt -and $activity -and $activity -gt $lastPingAt.AddSeconds(90)) {
        $pingStreak = 0
    }

    $idle = $null
    if ($activity) { $idle = [double]((Get-Date) - $activity).TotalMinutes }

    if ($snap.rate_limited) {
        Write-BridgeLog "skip ping: rate limited (cache is lost; watcher owns continue)" "DEBUG"
    }
    elseif ($null -eq $idle) {
        Write-BridgeLog "skip ping: no session history for cwd $ProjectCwd" "WARN"
    }
    elseif ($Force -or $idle -ge $idleMin) {
        if ($pingStreak -ge $maxStreak) {
            Write-BridgeLog "max_consecutive_pings=$maxStreak reached - pausing until session activity" "WARN"
        }
        elseif ($WhatIf) {
            Write-Host ("[WhatIf] Would ping session '{0}' (idle {1:N1}m, usage={2})" -f $SessionName, $idle, $snap.percent)
            $lastPingAt = Get-Date
            $pingStreak++
        }
        else {
            $why = if ($Force) { "forced" } else { "idle {0:N1}m >= {1}m" -f $idle, $idleMin }
            Write-BridgeLog "Pinging session to refresh cache ($why)"
            if (Invoke-SessionPing) {
                $lastPingAt = Get-Date
                $pingStreak++
            }
        }
    }
    else {
        Write-BridgeLog ("tick: idle {0:N1}m / need {1}m usage={2} limited={3} streak={4}" -f `
            $idle, $idleMin, $snap.percent, $snap.rate_limited, $pingStreak) "DEBUG"
    }

    if ($Once) { break }
    Start-Sleep -Seconds $pollSec
}

Write-BridgeLog "PING watch end"
