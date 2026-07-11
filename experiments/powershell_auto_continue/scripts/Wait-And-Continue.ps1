#Requires -Version 5.1
<#
.SYNOPSIS
  E2: Wait until usage limit reset, then start Claude with continue message.

.DESCRIPTION
  Does NOT inject into Cursor's existing terminal pane.
  Starts claude in a new window (or current) after sleep — best-effort native PS.

.EXAMPLE
  .\Wait-And-Continue.ps1 -ResetAt "17:00" -WhatIf
  .\Wait-And-Continue.ps1 -ResetAt "17:00"
  .\Wait-And-Continue.ps1 -UsageFile ..\..\..\.session_bridge\usage.json -NewWindow
#>
[CmdletBinding()]
param(
    [string] $ResetAt = "",
    [string] $UsageFile = "",
    [int] $MarginSeconds = 60,
    [string] $RetryMessage = "Continue where you left off after the usage limit reset. Re-read PROGRESS.md if present. Prefer the last agreed plan; do not re-litigate architecture unless blocked. Proceed autonomously.",
    [string] $ClaudeCommand = "claude",
    [string[]] $ClaudeArgs = @("-c"),
    [switch] $NewWindow = $true,
    [switch] $WhatIf,
    [switch] $SkipNotify
)

$ErrorActionPreference = "Stop"

function Resolve-UsagePath {
    param([string] $Path)
    if ($Path) { return $Path }
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
    return (Join-Path $repoRoot ".session_bridge\usage.json")
}

function Get-ResetDateTime {
    param([string] $ResetAt, [string] $UsageFile)

    if ($ResetAt) {
        if ($ResetAt -match '^\d{1,2}:\d{2}') {
            $dt = [datetime]::Parse(((Get-Date).ToString("yyyy-MM-dd") + " " + $ResetAt))
            if (((Get-Date) - $dt).TotalSeconds -gt 120) {
                $dt = $dt.AddDays(1)
            }
            return $dt
        }
        return [datetime]::Parse($ResetAt)
    }

    $path = Resolve-UsagePath -Path $UsageFile
    if (-not (Test-Path $path)) {
        throw "No -ResetAt and usage file missing: $path. Run Register-Usage.ps1 first."
    }
    $data = Get-Content $path -Raw | ConvertFrom-Json
    if (-not $data.reset_at) {
        throw "usage.json has no reset_at"
    }
    return [datetime]::Parse($data.reset_at)
}

function Test-ClaudeOnPath {
    param([string] $Cmd)
    $cmdInfo = Get-Command $Cmd -ErrorAction SilentlyContinue
    return $null -ne $cmdInfo
}

$when = Get-ResetDateTime -ResetAt $ResetAt -UsageFile $UsageFile
$target = $when.AddSeconds($MarginSeconds)
$now = Get-Date
$delay = ($target - $now).TotalSeconds

Write-Host "=== PowerShell experiment E2: Wait-And-Continue ==="
Write-Host "Reset at:     $when"
Write-Host "Launch after: $target (margin ${MarginSeconds}s)"
Write-Host "Claude:       $ClaudeCommand $($ClaudeArgs -join ' ')"
Write-Host "NewWindow:    $NewWindow"
Write-Host "Message:      $($RetryMessage.Substring(0, [Math]::Min(60, $RetryMessage.Length)))..."

if (-not (Test-ClaudeOnPath -Cmd $ClaudeCommand)) {
    Write-Warning "Command '$ClaudeCommand' not found on PATH. Install Claude Code CLI or pass -ClaudeCommand."
    if (-not $WhatIf) { exit 1 }
}

if ($WhatIf) {
    Write-Host "[WhatIf] Would sleep $([math]::Max(0, [math]::Round($delay)))s then launch Claude."
    exit 0
}

if ($delay -gt 0) {
    Write-Host "Sleeping $([math]::Round($delay)) seconds until reset+margin..."
    # Chunked sleep so Ctrl+C works more responsively
    $left = [math]::Ceiling($delay)
    while ($left -gt 0) {
        $chunk = [math]::Min(30, $left)
        Start-Sleep -Seconds $chunk
        $left -= $chunk
        if ($left -gt 0) {
            Write-Host "  ... ${left}s left"
        }
    }
} else {
    Write-Host "Reset time already passed — launching now."
}

if (-not $SkipNotify) {
    try {
        & (Join-Path $PSScriptRoot "Notify-Limit.ps1") -ResetAt $when.ToString("o") -MarginSeconds 0 -Wait:$false
    } catch {
        Write-Host "Notify skipped: $_"
    }
}

# Clear rate_limited in usage file if present
try {
    $uf = Resolve-UsagePath -Path $UsageFile
    if (Test-Path $uf) {
        $u = Get-Content $uf -Raw | ConvertFrom-Json
        $u | Add-Member -NotePropertyName rate_limited -NotePropertyValue $false -Force
        $u | Add-Member -NotePropertyName updated_at -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("o")) -Force
        $ufResolved = $uf
        if (-not [System.IO.Path]::IsPathRooted($ufResolved)) {
            $ufResolved = Join-Path (Get-Location).Path $ufResolved
        }
        $json = $u | ConvertTo-Json
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($ufResolved, $json, $utf8NoBom)
        Write-Host "Updated usage file rate_limited=false"
    }
} catch {
    Write-Host "Could not update usage file: $_"
}

# Launch Claude. Interactive continue message: write to temp prompt file if -p supported,
# else start interactive and rely on user/session; we pass message via stdin when possible.
$argLine = ($ClaudeArgs -join " ")
Write-Host "Starting Claude..."

if ($NewWindow) {
    # New PowerShell window, interactive claude -c; user may need to paste once if CLI ignores stdin
    $escapedMsg = $RetryMessage.Replace("'", "''")
    $cmd = @"
Write-Host 'Session Bridge E2 — sending continue...';
& '$ClaudeCommand' $argLine
Write-Host ''
Write-Host 'If Claude is idle at a prompt, paste:'
Write-Host '$escapedMsg'
"@
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoExit", "-Command", $cmd
    )
    Write-Host "Launched new PowerShell window with claude $argLine"
    Write-Host "Paste continue message if the session does not auto-read it."
} else {
    Write-Host $RetryMessage
    & $ClaudeCommand @ClaudeArgs
}

Write-Host "E2 done."
