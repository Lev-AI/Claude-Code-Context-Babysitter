#Requires -Version 5.1
<#
.SYNOPSIS
  HEAVY reliable watcher: poll usage.json, MAINTAIN signal, wait+continue on limit.

.DESCRIPTION
  Long-running loop (reliable path, no SendKeys):
  1) Read usage.json (filled by statusline-bridge.ps1)
  2) If percent >= maintain -> log MAINTAIN / optional session_bridge run --once
  3) If rate_limited or percent >= limit -> wait until reset_at + Invoke-HeavyContinue

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
$maintainCfg = Get-Prop $cfg "maintain"
$notify = Get-Prop $cfg "notify"

$stopFile = Join-Path (Get-ExperimentRoot) ".state\STOP"
# A STOP file left from a previous stop would kill us on the first tick
if (Test-Path $stopFile) {
    Remove-Item $stopFile -Force -ErrorAction SilentlyContinue
    Write-BridgeLog "Removed stale STOP file on startup"
}
$repo = Get-RepoRoot
$py = Join-Path $repo ".venv\Scripts\python.exe"
if (-not (Test-Path $py)) { $py = "python" }

Write-BridgeLog "HEAVY watch start cwd=$($state.project_cwd) session=$($state.session_name) usageFile=$usageFile poll=${poll}s"
Write-Host "Stop: create $stopFile  or Ctrl+C"
Save-RuntimeState -State $state

$continueFiredForReset = $null

while ($true) {
    if (Test-Path $stopFile) {
        Write-BridgeLog "STOP file present - exiting watch"
        $state.phase = "stopped"
        Save-RuntimeState -State $state
        break
    }

    $snap = Get-UsageSnapshot -UsageFile $usageFile
    $pct = $snap.percent
    $limited = [bool]$snap.rate_limited
    if ($null -ne $pct -and $pct -ge $limitPct) { $limited = $true }

    Write-BridgeLog "tick usage=$pct limited=$limited reset=$($snap.reset_at) age=$($snap.age_seconds)s phase=$($state.phase)" "DEBUG"

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

Write-BridgeLog "HEAVY watch end"
