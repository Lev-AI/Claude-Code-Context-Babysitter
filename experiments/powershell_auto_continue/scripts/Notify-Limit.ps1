#Requires -Version 5.1
<#
.SYNOPSIS
  E1: Notify when Claude usage limit resets (beep + tray balloon).

.EXAMPLE
  .\Notify-Limit.ps1 -ResetAt "17:00"
  .\Notify-Limit.ps1 -UsageFile ..\..\..\.session_bridge\usage.json
  .\Notify-Limit.ps1 -ResetAt "17:00" -Wait
#>
[CmdletBinding()]
param(
    [string] $ResetAt = "",
    [string] $UsageFile = "",
    [string] $Message = "Claude Code limit window reset - type continue (or run Wait-And-Continue).",
    [switch] $Wait,
    [int] $MarginSeconds = 60,
    [switch] $NoBeep
)

$ErrorActionPreference = "Stop"

function Resolve-UsagePath {
    param([string] $Path)
    if ($Path) { return $Path }
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
    return (Join-Path $repoRoot ".session_bridge\usage.json")
}

function Get-ResetDateTime {
    param([string] $ResetAtArg, [string] $UsageFileArg)

    if ($ResetAtArg) {
        if ($ResetAtArg -match '^\d{1,2}:\d{2}') {
            $day = Get-Date -Format "yyyy-MM-dd"
            $dt = [datetime]::Parse("$day $ResetAtArg")
            if (((Get-Date) - $dt).TotalSeconds -gt 120) {
                $dt = $dt.AddDays(1)
            }
            return $dt
        }
        return [datetime]::Parse($ResetAtArg)
    }

    $path = Resolve-UsagePath -Path $UsageFileArg
    if (-not (Test-Path $path)) {
        throw "No -ResetAt and usage file missing: $path"
    }
    $data = Get-Content $path -Raw | ConvertFrom-Json
    if ($data.reset_at) {
        return [datetime]::Parse($data.reset_at)
    }
    throw "usage.json has no reset_at. Pass -ResetAt or run Register-Usage.ps1 -ResetAt ..."
}

function Show-Balloon {
    param([string] $Title, [string] $Text)
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = [System.Drawing.SystemIcons]::Information
    $ni.Visible = $true
    $ni.BalloonTipTitle = $Title
    $ni.BalloonTipText = $Text
    $ni.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $ni.ShowBalloonTip(8000)
    Start-Sleep -Seconds 2
    $ni.Dispose()
}

$when = Get-ResetDateTime -ResetAtArg $ResetAt -UsageFileArg $UsageFile
$target = $when.AddSeconds($MarginSeconds)
$now = Get-Date

Write-Host "Reset at:  $when"
Write-Host "Notify at: $target (margin ${MarginSeconds}s)"
Write-Host "Now:       $now"

if ($Wait) {
    $delay = ($target - $now).TotalSeconds
    if ($delay -gt 0) {
        Write-Host "Sleeping $([math]::Round($delay))s ..."
        Start-Sleep -Seconds ([math]::Ceiling($delay))
    }
    else {
        Write-Host "Target already passed - notify now."
    }
}

if (-not $NoBeep) {
    try {
        [Console]::Beep(880, 300)
        [Console]::Beep(1175, 400)
    }
    catch {
        Write-Host "`a"
    }
}

Show-Balloon -Title "Claude Session Bridge (E1)" -Text $Message
Write-Host $Message
Write-Host "E1 done. For auto relaunch see Wait-And-Continue.ps1"
