#Requires -Version 5.1
<#
.SYNOPSIS
  One-command launcher: claude named session + limit watcher + cache pinger.

.DESCRIPTION
  Run from (or point at) any project folder. Opens three things:
    1. Claude window:  claude -n <SessionName>   (interactive, in project cwd)
    2. Watcher window (minimized):  Start-HeavyWatch.ps1  - waits limit, auto-continues
    3. Pinger window (minimized):   Ping-Session.ps1      - keeps prompt cache warm

  SessionName defaults to the project folder name.
  Stop everything: Stop-HeavyWatch.ps1 (shared STOP file).

.EXAMPLE
  cd C:\work\my-app
  & "...\powershell_auto_continue\scripts\Start-Babysitter.ps1"

  .\Start-Babysitter.ps1 -ProjectCwd "C:\work\my-app" -SessionName "feature-x"
  .\Start-Babysitter.ps1 -NoClaudeWindow   # only watcher + pinger
  .\Start-Babysitter.ps1 -WhatIf
#>
[CmdletBinding()]
param(
    [string] $ProjectCwd = "",
    [string] $SessionName = "",
    [string] $ConfigPath = "",
    [switch] $NoPing,
    [switch] $NoClaudeWindow,
    [switch] $WhatIf
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\lib\Common.ps1")

if (-not $ProjectCwd) { $ProjectCwd = (Get-Location).Path }
if (-not (Test-Path $ProjectCwd)) { throw "Project cwd does not exist: $ProjectCwd" }
$ProjectCwd = (Resolve-Path $ProjectCwd).Path
if (-not $SessionName) { $SessionName = Split-Path $ProjectCwd -Leaf }
# Session names travel through several command lines (incl. powershell -Command),
# so restrict to safe characters - a hostile folder name must not inject commands
$SessionName = ($SessionName -replace '[^A-Za-z0-9._-]', '-')

if (-not (Test-ClaudeAvailable)) { throw "Claude CLI not on PATH ('claude')" }

# Warn if statusLine bridge is not wired (usage.json will stay stale)
$settingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"
$slOk = $false
if (Test-Path $settingsPath) {
    try {
        $settings = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $slCmd = [string](Get-Prop (Get-Prop $settings "statusLine") "command" "")
        if ($slCmd -like "*statusline-bridge.ps1*") { $slOk = $true }
    }
    catch { }
}
if (-not $slOk) {
    Write-Host "WARN: statusLine bridge is not configured in $settingsPath" -ForegroundColor Yellow
    Write-Host "      Run scripts\Install-Heavy.ps1 once, otherwise usage.json will not update." -ForegroundColor Yellow
}

$stopFile = Join-Path (Get-ExperimentRoot) ".state\STOP"
$watcher = Join-Path $PSScriptRoot "Start-HeavyWatch.ps1"
$pinger = Join-Path $PSScriptRoot "Ping-Session.ps1"

# Config summary for the two opt-in behaviors handled by the children
$cfg = Read-HeavyConfig -ConfigPath $ConfigPath
$power = Get-BridgePowerConfig -Config $cfg
$stopCfg = Get-Prop $cfg "stop"
$stopEnabled = [bool](Get-Prop $stopCfg "enabled" $false)
$stopPct = [double](Get-Prop (Get-Prop $cfg "thresholds") "stop_percent" 88.0)

function Get-ChildArgs {
    param([string] $Script)
    $list = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", "`"$Script`"",
        "-ProjectCwd", "`"$ProjectCwd`"",
        "-SessionName", "`"$SessionName`""
    )
    if ($ConfigPath) { $list += @("-ConfigPath", "`"$ConfigPath`"") }
    return $list
}

Write-Host "=== Session Bridge Babysitter ===" -ForegroundColor Cyan
Write-Host "Project:  $ProjectCwd"
Write-Host "Session:  $SessionName"
Write-Host "Watcher:  $watcher"
Write-Host "Pinger:   $(if ($NoPing) { 'disabled (-NoPing)' } else { $pinger })"
Write-Host "Claude:   $(if ($NoClaudeWindow) { 'not opened (-NoClaudeWindow)' } else { "claude -n $SessionName" })"
Write-Host "Power:    $(if ($power.prevent_sleep) { "prevent_sleep on (scope=$($power.scope))" } else { 'prevent_sleep off (OS sleep policy applies)' })"
Write-Host "SoftStop: $(if ($stopEnabled) { "at $stopPct% (Ctrl+C to the Claude window)" } else { 'disabled' })"

if ($WhatIf) {
    Write-Host "[WhatIf] Would remove stale STOP (if present): $stopFile"
    Write-Host "[WhatIf] Would start (minimized): powershell $(Get-ChildArgs $watcher)"
    if (-not $NoPing) {
        Write-Host "[WhatIf] Would start (minimized): powershell $(Get-ChildArgs $pinger)"
    }
    if (-not $NoClaudeWindow) {
        Write-Host "[WhatIf] Would open window: claude -n $SessionName (cwd $ProjectCwd)"
        Write-Host "[WhatIf] Would record its PID in .state\claude_window.json (soft-stop target)"
    }
    exit 0
}

if (Test-Path $stopFile) {
    Remove-Item $stopFile -Force
    Write-Host "Removed stale STOP file"
}

$w = Start-Process powershell -ArgumentList (Get-ChildArgs $watcher) -WindowStyle Minimized -PassThru
Write-BridgeLog "Babysitter: watcher started PID=$($w.Id) session=$SessionName cwd=$ProjectCwd"

if (-not $NoPing) {
    $p = Start-Process powershell -ArgumentList (Get-ChildArgs $pinger) -WindowStyle Minimized -PassThru
    Write-BridgeLog "Babysitter: pinger started PID=$($p.Id)"
}

if (-not $NoClaudeWindow) {
    $c = Start-Process powershell -ArgumentList @(
        "-NoExit", "-Command", "claude -n $SessionName"
    ) -WorkingDirectory $ProjectCwd -PassThru
    # Record the window PID so the watcher's soft-stop targets exactly this window
    Write-JsonFile -Path (Get-DefaultClaudeWindowPath) -Object ([ordered]@{
        pid          = $c.Id
        session_name = $SessionName
        project_cwd  = $ProjectCwd
        started_at   = (Get-Date).ToString("o")
    })
    Write-BridgeLog "Babysitter: claude window opened PID=$($c.Id) (claude -n $SessionName)"
}

Write-Host ""
Write-Host "Started. In the Claude window: Shift+Tab -> Auto Mode; keep PROGRESS.md updated." -ForegroundColor Green
Write-Host "Stop everything: & `"$PSScriptRoot\Stop-HeavyWatch.ps1`""
