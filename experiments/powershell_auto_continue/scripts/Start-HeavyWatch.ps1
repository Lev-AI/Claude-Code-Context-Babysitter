#Requires -Version 5.1
<#
.SYNOPSIS
  HEAVY reliable watcher: poll usage.json, soft-stop, MAINTAIN signal, wait+continue on limit.

.DESCRIPTION
  Long-running loop (reliable path, no SendKeys):
  1) Read usage.json (filled by statusline-bridge.ps1)
  2) If percent >= stop_percent and stop.enabled -> soft-stop: Ctrl+C to the
     interactive Claude window recorded by Start-Babysitter (once per usage window),
     so the last percent before the hard limit is not burned mid-turn
  3) If percent >= maintain -> log MAINTAIN / optional session_bridge run --once
  4) If rate_limited or percent >= limit -> wait until reset_at + Invoke-HeavyContinue

  With power.prevent_sleep enabled (scope babysitter/watcher) the loop holds
  SetThreadExecutionState so Windows idle auto-sleep cannot freeze it.

.EXAMPLE
  .\Start-HeavyWatch.ps1
  .\Start-HeavyWatch.ps1 -ProjectCwd "C:\work\app" -SessionName "feature-x"
  .\Start-HeavyWatch.ps1 -Once
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = "",
    [string] $ProjectCwd = "",
    [string] $SessionName = "",
    [switch] $Once,
    [switch] $WhatIf
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\lib\ClaudeLaunch.ps1")

$cfg = Read-HeavyConfig -ConfigPath $ConfigPath
$cfgUsageFile = Get-Prop $cfg "usage_file"
$usageFile = [System.IO.Path]::GetFullPath((Join-Path (Get-ExperimentRoot) $(
    if ($cfgUsageFile) { $cfgUsageFile } else { "../../.session_bridge/usage.json" }
)))

$state = Get-RuntimeState
$cfgProjectCwd = Get-Prop $cfg "project_cwd"
if ($ProjectCwd) { $state.project_cwd = $ProjectCwd }
elseif ($cfgProjectCwd) { $state.project_cwd = $cfgProjectCwd }
elseif (-not $state.project_cwd) { $state.project_cwd = (Get-Location).Path }

$cfgSessionName = Get-Prop $cfg "session_name"
if ($SessionName) { $state.session_name = $SessionName }
elseif ($cfgSessionName) { $state.session_name = $cfgSessionName }

$watchCfg = Get-Prop $cfg "watch"
$poll = [int](Get-Prop $watchCfg "poll_seconds" 30)
$thresholds = Get-Prop $cfg "thresholds"
$maintainPct = [double](Get-Prop $thresholds "maintain_percent" 95.0)
$limitPct = [double](Get-Prop $thresholds "limit_percent" 99.5)
$stopPct = [double](Get-Prop $thresholds "stop_percent" 88.0)
$maintainCfg = Get-Prop $cfg "maintain"
$notify = Get-Prop $cfg "notify"

$stopCfg = Get-Prop $cfg "stop"
$stopEnabled = [bool](Get-Prop $stopCfg "enabled" $false)
$stopMethod = [string](Get-Prop $stopCfg "method" "ctrl_c")
$stopOncePerReset = [bool](Get-Prop $stopCfg "once_per_reset" $true)
$stopNotify = [bool](Get-Prop $stopCfg "notify" $true)

$power = Get-BridgePowerConfig -Config $cfg
$holdPower = Test-BridgePowerScope -Power $power -Component "watcher"

$stopFile = Join-Path (Get-ExperimentRoot) ".state\STOP"
# A STOP file left from a previous stop would kill us on the first tick
if (Test-Path $stopFile) {
    Remove-Item $stopFile -Force -ErrorAction SilentlyContinue
    Write-BridgeLog "Removed stale STOP file on startup"
}
$repo = Get-RepoRoot
$py = Join-Path $repo ".venv\Scripts\python.exe"
if (-not (Test-Path $py)) { $py = "python" }

function Invoke-SoftStop {
    <#
      Interrupt the interactive Claude window before the hard limit.
      Only ever targets the PID recorded by Start-Babysitter in
      claude_window.json - never searches for claude processes.
    #>
    param([double] $Percent)
    $sent = $false
    if ($stopMethod -eq "ctrl_c") {
        $target = $null
        $info = Read-JsonFile -Path (Get-DefaultClaudeWindowPath)
        if ($info) {
            $infoPid = Get-Prop $info "pid"
            $infoSession = [string](Get-Prop $info "session_name" "")
            if ($infoPid -and $state.session_name -and $infoSession -and $infoSession -ne $state.session_name) {
                Write-BridgeLog "soft-stop: recorded window session '$infoSession' != watcher session '$($state.session_name)' - not touching it" "WARN"
            }
            elseif ($infoPid) {
                try {
                    $proc = Get-Process -Id ([int]$infoPid) -ErrorAction Stop
                    $recorded = Get-Prop $info "started_at"
                    # PID-recycling guard: the live process must match the recorded launch time
                    if ($recorded -and [math]::Abs(($proc.StartTime - [datetime]::Parse($recorded)).TotalSeconds) -gt 120) {
                        Write-BridgeLog "soft-stop: PID $infoPid start time differs from claude_window.json (recycled pid?) - not touching it" "WARN"
                    }
                    else { $target = $proc.Id }
                }
                catch {
                    Write-BridgeLog "soft-stop: recorded Claude window PID $infoPid is not running" "WARN"
                }
            }
        }
        else {
            Write-BridgeLog "soft-stop: no claude_window.json (Claude window not started via Start-Babysitter?)" "WARN"
        }
        if ($target) {
            Write-BridgeLog "SOFT-STOP: usage $Percent% >= stop_percent $stopPct% - sending Ctrl+C to Claude window PID=$target" "WARN"
            $sent = Send-ConsoleCtrlC -TargetPid $target
            if (-not $sent) { Write-BridgeLog "SOFT-STOP: Ctrl+C delivery failed - stop the turn manually" "WARN" }
        }
    }
    else {
        Write-BridgeLog "SOFT-STOP: usage $Percent% >= stop_percent $stopPct% (method=$stopMethod - notify only)" "WARN"
    }
    if ($stopNotify) {
        $rounded = [math]::Round($Percent)
        $txt = if ($sent) {
            "Soft-stopped Claude at $rounded% (before hard limit). Pinger keeps cache warm; auto-continue after reset."
        }
        else {
            "Usage $rounded% >= stop threshold $stopPct%. Stop the current Claude turn (Ctrl+C); auto-continue after reset."
        }
        Show-BridgeNotify -Text $txt -Beep:([bool](Get-Prop $notify "beep"))
    }
    return $sent
}

$stopDesc = if ($stopEnabled) { "$stopPct% ($stopMethod)" } else { "off" }
Write-BridgeLog "HEAVY watch start cwd=$($state.project_cwd) session=$($state.session_name) usageFile=$usageFile poll=${poll}s soft-stop=$stopDesc prevent_sleep=$holdPower"
Write-Host "Stop: create $stopFile  or Ctrl+C"
Save-RuntimeState -State $state

$continueFiredForReset = $null
$softStopFiredForReset = $null

try {
    if ($holdPower) { [void](Enable-BridgePreventSleep -KeepDisplayOn:($power.keep_display_on)) }

    while ($true) {
        if (Test-Path $stopFile) {
            Write-BridgeLog "STOP file present - exiting watch"
            $state.phase = "stopped"
            Save-RuntimeState -State $state
            break
        }

        # Re-assert prevent-sleep each tick (cheap; logs only when state changes)
        if ($holdPower) { [void](Enable-BridgePreventSleep -KeepDisplayOn:($power.keep_display_on)) }

        $snap = Get-UsageSnapshot -UsageFile $usageFile
        $pct = $snap.percent
        $limited = [bool]$snap.rate_limited
        if ($null -ne $pct -and $pct -ge $limitPct) { $limited = $true }

        Write-BridgeLog "tick usage=$pct limited=$limited reset=$($snap.reset_at) age=$($snap.age_seconds)s phase=$($state.phase)" "DEBUG"

        # SOFT-STOP band: interrupt the interactive window before the hard limit
        if ($stopEnabled -and $null -ne $pct -and -not $limited) {
            if ($pct -lt $stopPct) {
                # usage window reset below the threshold -> re-arm
                if ($softStopFiredForReset) { $softStopFiredForReset = $null }
            }
            else {
                $stopKey = if ($snap.reset_at) { [string]$snap.reset_at } else { "no-reset-key" }
                if (-not ($stopOncePerReset -and $softStopFiredForReset -eq $stopKey)) {
                    if ($WhatIf) {
                        Write-Host "[WhatIf] Would soft-stop Claude window (usage $pct% >= $stopPct%)"
                    }
                    else {
                        [void](Invoke-SoftStop -Percent $pct)
                    }
                    $softStopFiredForReset = $stopKey
                    if ($state.phase -notin @("maintain", "waiting", "continuing")) {
                        $state.phase = "soft_stopped"
                        Save-RuntimeState -State $state
                    }
                }
            }
        }

        # MAINTAIN band
        if ($null -ne $pct -and $pct -ge $maintainPct -and -not $limited) {
            if ($state.phase -ne "maintain" -and $state.phase -ne "waiting" -and $state.phase -ne "continuing") {
                $state.phase = "maintain"
                Save-RuntimeState -State $state
                Write-BridgeLog "Entered MAINTAIN (usage $pct% >= $maintainPct%)" "WARN"
                if (Get-Prop $maintainCfg "call_session_bridge") {
                    $prevEap = $ErrorActionPreference
                    $prevPyEncoding = $env:PYTHONIOENCODING
                    try {
                        Push-Location $repo
                        $ErrorActionPreference = "Continue"
                        $env:PYTHONIOENCODING = "utf-8"
                        & $py -m session_bridge run --once 2>&1 | ForEach-Object { Write-BridgeLog "bridge: $_" "DEBUG" }
                        if ($LASTEXITCODE -eq 0) {
                            Write-BridgeLog "session_bridge run --once OK" "DEBUG"
                        }
                        else {
                            Write-BridgeLog "session_bridge run --once exited with code $LASTEXITCODE" "WARN"
                        }
                    }
                    catch {
                        Write-BridgeLog "session_bridge once failed: $_" "WARN"
                    }
                    finally {
                        $ErrorActionPreference = $prevEap
                        $env:PYTHONIOENCODING = $prevPyEncoding
                        Pop-Location
                    }
                }
            }
        }

        # LIMIT -> wait + continue (once per reset_at value)
        if ($limited) {
            $resetKey = $snap.reset_at
            if (-not $resetKey -and $snap.reset_at_dt) {
                $resetKey = $snap.reset_at_dt.ToString("o")
            }

            if ($resetKey -and $resetKey -eq $continueFiredForReset) {
                Write-BridgeLog "Continue already scheduled/fired for reset $resetKey" "DEBUG"
            }
            else {
                Write-BridgeLog "LIMIT detected - scheduling heavy continue" "WARN"
                if (Get-Prop $notify "on_limit_detected") {
                    Show-BridgeNotify -Text "Claude limit hit. Will continue after reset." -Beep:([bool](Get-Prop $notify "beep"))
                }
                $state.phase = "waiting"
                $state.last_reset_at = $resetKey
                Save-RuntimeState -State $state

                if ($WhatIf) {
                    Write-Host "[WhatIf] Would Invoke-HeavyContinue for reset=$resetKey"
                    $continueFiredForReset = $resetKey
                }
                else {
                    $continueArgs = @{
                        ProjectCwd  = $state.project_cwd
                        SessionName = $state.session_name
                    }
                    if ($ConfigPath) { $continueArgs.ConfigPath = $ConfigPath }
                    if ($snap.reset_at_dt) {
                        $continueArgs.ResetAt = $snap.reset_at_dt.ToString("o")
                    }
                    try {
                        & (Join-Path $PSScriptRoot "Invoke-HeavyContinue.ps1") @continueArgs
                        $continueFiredForReset = $resetKey
                        $state = Get-RuntimeState
                    }
                    catch {
                        Write-BridgeLog "Heavy continue failed: $_" "ERROR"
                        $state.phase = "error"
                        $state.last_error = "$_"
                        Save-RuntimeState -State $state
                    }
                }
            }
        }
        elseif ($state.phase -eq "maintain" -or $state.phase -eq "waiting") {
            # recover soft
            if ($null -eq $pct -or $pct -lt $maintainPct) {
                $state.phase = if ($stopEnabled -and $null -ne $pct -and $pct -ge $stopPct) { "soft_stopped" } else { "active" }
                Save-RuntimeState -State $state
                Write-BridgeLog "Recovered to $($state.phase) (usage=$pct)"
            }
        }
        elseif ($state.phase -eq "soft_stopped") {
            if ($null -eq $pct -or $pct -lt $stopPct) {
                $state.phase = "active"
                Save-RuntimeState -State $state
                Write-BridgeLog "Recovered to active (usage=$pct)"
            }
        }
        elseif ($state.phase -eq "idle") {
            $state.phase = "active"
            Save-RuntimeState -State $state
        }

        if ($Once) { break }
        Start-Sleep -Seconds $poll
    }
}
finally {
    if ($holdPower) { Disable-BridgePreventSleep }
}

Write-BridgeLog "HEAVY watch end"
