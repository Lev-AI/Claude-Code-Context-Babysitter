#Requires -Version 5.1
<#
.SYNOPSIS
  HEAVY reliable continue: wait until reset_at (optional), then claude -c/--resume -p with retries.

.EXAMPLE
  .\Invoke-HeavyContinue.ps1 -WhatIf
  .\Invoke-HeavyContinue.ps1 -ProjectCwd "C:\work\myapp" -SessionName "feature-x"
  .\Invoke-HeavyContinue.ps1 -SkipWait
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = "",
    [string] $ProjectCwd = "",
    [string] $SessionName = "",
    [string] $ResetAt = "",
    [switch] $SkipWait,
    [switch] $WhatIf
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\lib\ClaudeLaunch.ps1")

$cfg = Read-HeavyConfig -ConfigPath $ConfigPath
$cfgUsageFile = Get-Prop $cfg "usage_file"
$usageFile = if ($cfgUsageFile) {
    $p = Join-Path (Get-ExperimentRoot) $cfgUsageFile
    if (Test-Path $p) { (Resolve-Path $p).Path } else {
        $abs = $cfgUsageFile
        if (-not [System.IO.Path]::IsPathRooted($abs)) {
            $abs = Join-Path (Get-ExperimentRoot) $cfgUsageFile
        }
        $abs
    }
} else { Get-DefaultUsagePath }

# Normalize relative usage path from config (../../.session_bridge/...)
if ($cfgUsageFile -and -not [System.IO.Path]::IsPathRooted($cfgUsageFile)) {
    $usageFile = [System.IO.Path]::GetFullPath((Join-Path (Get-ExperimentRoot) $cfgUsageFile))
}

$snap = Get-UsageSnapshot -UsageFile $usageFile
$state = Get-RuntimeState

$cfgProjectCwd = Get-Prop $cfg "project_cwd"
if ($ProjectCwd) { $state.project_cwd = $ProjectCwd }
elseif ($cfgProjectCwd) { $state.project_cwd = $cfgProjectCwd }
elseif (-not $state.project_cwd) { $state.project_cwd = (Get-Location).Path }

$cfgSessionName = Get-Prop $cfg "session_name"
if ($SessionName) { $state.session_name = $SessionName }
elseif ($cfgSessionName) { $state.session_name = $cfgSessionName }

$notify = Get-Prop $cfg "notify"

$resetDt = $null
if ($ResetAt) {
    $resetDt = Parse-ResetDateTime -Value $ResetAt
}
elseif ($snap.reset_at_dt) {
    $resetDt = $snap.reset_at_dt
}

$wait = Get-Prop $cfg "wait"
$margin = [int](Get-Prop $wait "margin_seconds" 90)
$maxWaitH = [double](Get-Prop $wait "max_wait_hours" 6)
$chunk = [int](Get-Prop $wait "chunk_sleep_seconds" 30)

Write-BridgeLog "HEAVY continue: cwd=$($state.project_cwd) session=$($state.session_name) reset=$resetDt usage=$($snap.percent)% limited=$($snap.rate_limited)"

# Compute the wait decision up front, with NO side effects yet, so -WhatIf can
# report accurately even when reset_at is already in the past.
$target = $null
$delay = 0
$willWait = $false
if (-not $SkipWait -and $resetDt) {
    $target = $resetDt.AddSeconds($margin)
    $delay = ($target - (Get-Date)).TotalSeconds
    if ($delay -gt ($maxWaitH * 3600)) {
        throw "Wait $([math]::Round($delay/3600,1))h exceeds max_wait_hours=$maxWaitH"
    }
    if ($delay -gt 0) { $willWait = $true }
}

if ($WhatIf) {
    if ($willWait) {
        Write-Host "[WhatIf] Would wait $([math]::Round($delay))s until $target then continue"
    }
    else {
        Write-Host "[WhatIf] Would continue immediately (no reset_at / -SkipWait / reset already passed)"
    }
    exit 0
}

if ($willWait) {
    $state.phase = "waiting"
    $state.last_reset_at = $resetDt.ToString("o")
    Save-RuntimeState -State $state
    Write-BridgeLog "Sleeping $([math]::Round($delay))s until $target"
    if (Get-Prop $notify "on_limit_detected") {
        Show-BridgeNotify -Text "Waiting for Claude limit reset at $resetDt" -Beep:([bool](Get-Prop $notify "beep"))
    }
    $left = [math]::Ceiling($delay)
    while ($left -gt 0) {
        $step = [math]::Min($chunk, $left)
        Start-Sleep -Seconds $step
        $left -= $step
        if ($left -gt 0 -and ($left % 300 -lt $chunk)) {
            Write-BridgeLog "Wait remaining ~${left}s"
        }
    }
}

# Clear rate_limited in usage file
try {
    if (Test-Path $usageFile) {
        $u = Read-JsonFile -Path $usageFile
        if ($u) {
            $u | Add-Member -NotePropertyName rate_limited -NotePropertyValue $false -Force
            $pctNow = Get-Prop $u "session_usage_percent"
            if ($null -eq $pctNow -or [double]$pctNow -ge 99) {
                $u | Add-Member -NotePropertyName session_usage_percent -NotePropertyValue 5 -Force
            }
            $u | Add-Member -NotePropertyName updated_at -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o")) -Force
            Write-JsonFile -Path $usageFile -Object $u
        }
    }
}
catch {
    Write-BridgeLog "usage clear failed: $_" "WARN"
}

$state.phase = "continuing"
Save-RuntimeState -State $state

$continueCfg = Get-Prop $cfg "continue"
$mode = [string](Get-Prop $continueCfg "mode" "both")
$claude = [string](Get-Prop $continueCfg "claude_command" "claude")
$msg = [string](Get-Prop $continueCfg "retry_message" "Continue where you left off after the usage limit reset.")
$attempts = [int](Get-Prop $continueCfg "max_attempts" 3)
$delayR = [int](Get-Prop $continueCfg "retry_delay_seconds" 25)
$newWin = [bool](Get-Prop $continueCfg "new_window" $true)

$result = Invoke-ClaudeContinue `
    -ProjectCwd $state.project_cwd `
    -ClaudeCommand $claude `
    -SessionName $state.session_name `
    -RetryMessage $msg `
    -Mode $mode `
    -NewWindow:$newWin `
    -MaxAttempts $attempts `
    -RetryDelaySeconds $delayR

$state.phase = "active"
$state.last_continue_at = (Get-Date).ToUniversalTime().ToString("o")
$state.continue_count = [int]$state.continue_count + 1
$state.last_error = ""
Save-RuntimeState -State $state

if (Get-Prop $notify "on_continue") {
    Show-BridgeNotify -Text "Claude continue launched ($($result.mode))" -Beep:([bool](Get-Prop $notify "beep"))
}

# Optional: tell main session_bridge to resume
$repo = Get-RepoRoot
$py = Join-Path $repo ".venv\Scripts\python.exe"
if (-not (Test-Path $py)) { $py = "python" }
$prevEap = $ErrorActionPreference
$prevPyEncoding = $env:PYTHONIOENCODING
try {
    Push-Location $repo
    $ErrorActionPreference = "Continue"
    $env:PYTHONIOENCODING = "utf-8"
    & $py -m session_bridge resume 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-BridgeLog "session_bridge resume OK" "DEBUG"
    }
    else {
        Write-BridgeLog "session_bridge resume exited with code $LASTEXITCODE" "WARN"
    }
}
catch {
    Write-BridgeLog "session_bridge resume skipped: $_" "DEBUG"
}
finally {
    $ErrorActionPreference = $prevEap
    $env:PYTHONIOENCODING = $prevPyEncoding
    Pop-Location
}

Write-BridgeLog "HEAVY continue finished: $($result | ConvertTo-Json -Compress)"
Write-Host "OK: continue mode=$($result.mode) attempt=$($result.attempt)"
