#Requires -Version 5.1
<#
.SYNOPSIS
  Keepalive pinger: keeps a named Claude session's prompt cache warm via headless --resume pings.

.DESCRIPTION
  While the session is idle (its history file unchanged for a random interval
  between ping_idle_min_minutes and ping_idle_max_minutes, default 45-55 min,
  seconds precision, re-drawn after every ping) and not rate-limited, sends:

      claude --resume <SessionName> -p "<keepalive message>"

  The message is drawn from the keepalive.messages pool (random_no_repeat by
  default) so pings do not repeat the same text; the legacy keepalive.message
  is the fallback when the pool is empty.

  Each ping re-reads the session context as a cache READ (~10% of full price) and
  refreshes the ~1h cache TTL, so after a limit reset the session continues warm
  instead of paying full cache-write for the whole context.

  With power.prevent_sleep enabled (scope babysitter/pinger) the loop holds
  SetThreadExecutionState so Windows idle auto-sleep cannot freeze it.

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
# Random idle target between min and max (seconds precision), re-drawn after
# every ping so the cadence never looks mechanical. A legacy fixed
# ping_after_idle_minutes value is honored as min = max.
$legacyIdle = Get-Prop $ka "ping_after_idle_minutes"
$idleMinM = [double](Get-Prop $ka "ping_idle_min_minutes" $(if ($null -ne $legacyIdle) { $legacyIdle } else { 45 }))
$idleMaxM = [double](Get-Prop $ka "ping_idle_max_minutes" $(if ($null -ne $legacyIdle) { $legacyIdle } else { 55 }))
if ($idleMaxM -lt $idleMinM) { $idleMaxM = $idleMinM }
$pollSec = [int](Get-Prop $ka "poll_seconds" 60)

function New-IdleTargetSeconds {
    $lo = [int][math]::Round($idleMinM * 60)
    $hi = [int][math]::Round($idleMaxM * 60)
    if ($hi -le $lo) { return $lo }
    return (Get-Random -Minimum $lo -Maximum ($hi + 1))
}

function Format-Sec {
    param([int] $Seconds)
    return ("{0}m{1:d2}s" -f [int][math]::Floor($Seconds / 60), [int]($Seconds % 60))
}

$msgFallback = [string](Get-Prop $ka "message" "ACK only: context keep-alive. Do not run tools. Reply with OK.")
$msgPool = @(Get-Prop $ka "messages" @()) | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() }
$msgPick = [string](Get-Prop $ka "message_pick" "random_no_repeat")
$script:lastPingMessage = $null
$script:rotateIndex = 0

function Get-PingMessage {
    # Draw from the pool (random_no_repeat | random | rotate); legacy single
    # 'message' is the fallback when the pool is empty.
    $pool = @($msgPool)
    if ($pool.Count -eq 0) { return $msgFallback }
    switch ($msgPick) {
        "rotate" {
            $m = $pool[$script:rotateIndex % $pool.Count]
            $script:rotateIndex++
            return [string]$m
        }
        "random" {
            return [string]($pool | Get-Random)
        }
        default {
            # random_no_repeat: avoid the previous message when there is a choice
            $candidates = $pool
            if ($pool.Count -gt 1 -and $script:lastPingMessage) {
                $candidates = @($pool | Where-Object { $_ -ne $script:lastPingMessage })
                if ($candidates.Count -eq 0) { $candidates = $pool }
            }
            return [string]($candidates | Get-Random)
        }
    }
}

$maxStreak = [int](Get-Prop $ka "max_consecutive_pings" 8)
$claude = [string](Get-Prop (Get-Prop $cfg "continue") "claude_command" "claude")

$power = Get-BridgePowerConfig -Config $cfg
$holdPower = Test-BridgePowerScope -Power $power -Component "pinger"

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
    $msg = Get-PingMessage
    $script:lastPingMessage = $msg
    $short = if ($msg.Length -gt 40) { $msg.Substring(0, 40) + "..." } else { $msg }
    Write-BridgeLog "PING msg=`"$short`"" "DEBUG"
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
$idleTargetSec = New-IdleTargetSeconds

Write-BridgeLog "PING watch start cwd=$ProjectCwd session=$SessionName idle-target=$(Format-Sec $idleTargetSec) (random $idleMinM-$idleMaxM min) poll=${pollSec}s messages=$(@($msgPool).Count) pick=$msgPick prevent_sleep=$holdPower usageFile=$usageFile"
if (-not $Once) { Write-Host "Stop: create $stopFile  or Ctrl+C" }

try {
    if ($holdPower) { [void](Enable-BridgePreventSleep -KeepDisplayOn:($power.keep_display_on)) }

    while ($true) {
        # -Once is an explicit manual invocation - it should not obey a STOP file
        if (-not $Once -and (Test-Path $stopFile)) {
            Write-BridgeLog "STOP file present - exiting ping watch"
            break
        }

        # Re-assert prevent-sleep each tick (cheap; logs only when state changes)
        if ($holdPower) { [void](Enable-BridgePreventSleep -KeepDisplayOn:($power.keep_display_on)) }

        $snap = Get-UsageSnapshot -UsageFile $usageFile
        $activity = Get-SessionLastActivity -Cwd $ProjectCwd

        # User (or watcher continue) touched the session after our last ping -> reset streak
        if ($lastPingAt -and $activity -and $activity -gt $lastPingAt.AddSeconds(90)) {
            $pingStreak = 0
        }

        $idleSec = $null
        if ($activity) { $idleSec = [int]((Get-Date) - $activity).TotalSeconds }

        if ($snap.rate_limited) {
            Write-BridgeLog "skip ping: rate limited (cache is lost; watcher owns continue)" "DEBUG"
        }
        elseif ($null -eq $idleSec) {
            Write-BridgeLog "skip ping: no session history for cwd $ProjectCwd" "WARN"
        }
        elseif ($Force -or $idleSec -ge $idleTargetSec) {
            if ($pingStreak -ge $maxStreak) {
                Write-BridgeLog "max_consecutive_pings=$maxStreak reached - pausing until session activity" "WARN"
            }
            elseif ($WhatIf) {
                $m = Get-PingMessage
                $script:lastPingMessage = $m
                Write-Host ("[WhatIf] Would ping session '{0}' (idle {1}, target {2}, usage={3}) msg: {4}" -f `
                    $SessionName, (Format-Sec $idleSec), (Format-Sec $idleTargetSec), $snap.percent, $m)
                $lastPingAt = Get-Date
                $pingStreak++
                $idleTargetSec = New-IdleTargetSeconds
                Write-Host "[WhatIf] Next idle target: $(Format-Sec $idleTargetSec)"
            }
            else {
                $why = if ($Force) { "forced" } else { "idle $(Format-Sec $idleSec) >= target $(Format-Sec $idleTargetSec)" }
                Write-BridgeLog "Pinging session to refresh cache ($why)"
                if (Invoke-SessionPing) {
                    $lastPingAt = Get-Date
                    $pingStreak++
                    $idleTargetSec = New-IdleTargetSeconds
                    Write-BridgeLog "Next ping after $(Format-Sec $idleTargetSec) of idle (random $idleMinM-$idleMaxM min)"
                }
            }
        }
        else {
            Write-BridgeLog ("tick: idle {0} / target {1} usage={2} limited={3} streak={4}" -f `
                (Format-Sec $idleSec), (Format-Sec $idleTargetSec), $snap.percent, $snap.rate_limited, $pingStreak) "DEBUG"
        }

        if ($Once) { break }
        Start-Sleep -Seconds $pollSec
    }
}
finally {
    if ($holdPower) { Disable-BridgePreventSleep }
}

Write-BridgeLog "PING watch end"
