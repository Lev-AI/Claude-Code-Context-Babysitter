#Requires -Version 5.1
# Shared helpers for heavy reliable PowerShell auto-continue experiment.

Set-StrictMode -Version Latest

function Get-ExperimentRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
}

function Get-DefaultUsagePath {
    return (Join-Path (Get-RepoRoot) ".session_bridge\usage.json")
}

function Get-DefaultStatePath {
    return (Join-Path (Get-ExperimentRoot) ".state\runtime.json")
}

function Get-DefaultClaudeWindowPath {
    # Written by Start-Babysitter, read by the watcher's soft-stop
    return (Join-Path (Get-ExperimentRoot) ".state\claude_window.json")
}

function Get-DefaultLogDir {
    return (Join-Path (Get-ExperimentRoot) ".state\logs")
}

function Write-BridgeLog {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string] $Level = "INFO"
    )
    $dir = Get-DefaultLogDir
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $day = Get-Date -Format "yyyy-MM-dd"
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "o"), $Level, $Message
    Add-Content -Path (Join-Path $dir "$day.log") -Value $line -Encoding UTF8
    $color = switch ($Level) {
        "WARN" { "Yellow" }
        "ERROR" { "Red" }
        "DEBUG" { "DarkGray" }
        default { "Gray" }
    }
    Write-Host $line -ForegroundColor $color
}

function Get-Prop {
    param($Object, [Parameter(Mandatory)][string] $Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -ne $p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        return (Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        Write-BridgeLog "JSON read failed: $Path :: $_" "WARN"
        return $null
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)] $Object
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json = $Object | ConvertTo-Json -Depth 8
    $resolvedPath = $Path
    if (-not [System.IO.Path]::IsPathRooted($resolvedPath)) {
        $resolvedPath = Join-Path (Get-Location).Path $resolvedPath
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($resolvedPath, $json, $utf8NoBom)
}

function Parse-ResetDateTime {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if ($Value -match '^\d{1,2}:\d{2}') {
        $day = Get-Date -Format "yyyy-MM-dd"
        $dt = [datetime]::Parse("$day $Value")
        if (((Get-Date) - $dt).TotalSeconds -gt 120) {
            $dt = $dt.AddDays(1)
        }
        return $dt
    }
    return [datetime]::Parse($Value)
}

function ConvertFrom-UnixSeconds {
    param($Seconds)
    if ($null -eq $Seconds) { return $null }
    try {
        return [DateTimeOffset]::FromUnixTimeSeconds([int64]$Seconds).LocalDateTime
    }
    catch {
        return $null
    }
}

function Get-UsageSnapshot {
    param([string] $UsageFile = (Get-DefaultUsagePath))

    $data = Read-JsonFile -Path $UsageFile
    $snap = [ordered]@{
        path           = $UsageFile
        exists         = [bool]$data
        percent        = $null
        rate_limited   = $false
        reset_at       = $null
        reset_at_dt    = $null
        source         = $null
        raw            = $data
        age_seconds    = $null
    }
    if (-not $data) { return [pscustomobject]$snap }

    if (Test-Path $UsageFile) {
        $snap.age_seconds = [int]((Get-Date) - (Get-Item $UsageFile).LastWriteTime).TotalSeconds
    }
    $sessionPct = Get-Prop $data "session_usage_percent"
    $usagePct = Get-Prop $data "usage_percent"
    if ($null -ne $sessionPct) {
        $snap.percent = [double]$sessionPct
    }
    elseif ($null -ne $usagePct) {
        $snap.percent = [double]$usagePct
    }
    $rateLimited = Get-Prop $data "rate_limited"
    if ($null -ne $rateLimited) {
        $snap.rate_limited = [bool]$rateLimited
    }
    $source = Get-Prop $data "source"
    if ($source) { $snap.source = [string]$source }
    $resetAt = Get-Prop $data "reset_at"
    if ($resetAt) {
        $snap.reset_at = [string]$resetAt
        try { $snap.reset_at_dt = [datetime]::Parse($resetAt) } catch { }
    }
    if (($null -eq $snap.percent) -and ($snap.rate_limited)) {
        $snap.percent = 100.0
    }
    return [pscustomobject]$snap
}

function Write-UsageSnapshot {
    param(
        [string] $UsageFile = (Get-DefaultUsagePath),
        [double] $Percent = 100,
        [bool] $RateLimited = $false,
        [string] $ResetAt = "",
        [string] $Source = "powershell_heavy"
    )
    $payload = [ordered]@{
        session_usage_percent = $Percent
        rate_limited          = $RateLimited
        updated_at            = (Get-Date).ToUniversalTime().ToString("o")
        source                = $Source
    }
    $dt = Parse-ResetDateTime -Value $ResetAt
    if ($dt) {
        $payload["reset_at"] = $dt.ToUniversalTime().ToString("o")
    }
    Write-JsonFile -Path $UsageFile -Object $payload
    Write-BridgeLog "Wrote usage: $UsageFile percent=$Percent rate_limited=$RateLimited"
}

function Get-RuntimeState {
    param([string] $StateFile = (Get-DefaultStatePath))
    $defaults = [ordered]@{
        phase              = "idle"
        project_cwd        = (Get-Location).Path
        session_name       = ""
        last_reset_at      = $null
        last_continue_at   = $null
        continue_count     = 0
        last_error         = ""
        updated_at         = (Get-Date).ToUniversalTime().ToString("o")
    }
    $data = Read-JsonFile -Path $StateFile
    if ($data) {
        foreach ($key in $defaults.Keys) {
            if ($null -eq $data.PSObject.Properties[$key]) {
                $data | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key]
            }
        }
        return $data
    }
    return [pscustomobject]$defaults
}

function Save-RuntimeState {
    param(
        [Parameter(Mandatory)] $State,
        [string] $StateFile = (Get-DefaultStatePath)
    )
    $State | Add-Member -NotePropertyName updated_at -NotePropertyValue (
        (Get-Date).ToUniversalTime().ToString("o")
    ) -Force
    Write-JsonFile -Path $StateFile -Object $State
}

function Test-ClaudeAvailable {
    param([string] $ClaudeCommand = "claude")
    return $null -ne (Get-Command $ClaudeCommand -ErrorAction SilentlyContinue)
}

function Show-BridgeNotify {
    param(
        [string] $Title = "Claude Session Bridge",
        [string] $Text,
        [switch] $Beep
    )
    if ($Beep) {
        try {
            [Console]::Beep(880, 250)
            [Console]::Beep(1175, 350)
        }
        catch {
            Write-Host "`a"
        }
    }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Information
        $ni.Visible = $true
        $ni.BalloonTipTitle = $Title
        $ni.BalloonTipText = $Text
        $ni.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $ni.ShowBalloonTip(10000)
        Start-Sleep -Seconds 2
        $ni.Dispose()
    }
    catch {
        Write-BridgeLog "Balloon notify failed: $_" "DEBUG"
    }
    Write-BridgeLog "NOTIFY: $Text"
}

function Read-HeavyConfig {
    param([string] $ConfigPath = "")
    $root = Get-ExperimentRoot
    if (-not $ConfigPath) {
        $local = Join-Path $root "config.local.json"
        $heavy = Join-Path $root "config.heavy.json"
        $ex = Join-Path $root "config.example.json"
        if (Test-Path $local) { $ConfigPath = $local }
        elseif (Test-Path $heavy) { $ConfigPath = $heavy }
        else { $ConfigPath = $ex }
    }
    $cfg = Read-JsonFile -Path $ConfigPath
    if (-not $cfg) {
        throw "Cannot load config: $ConfigPath"
    }
    return $cfg
}

# Win32 power/console helpers (prevent-sleep, console Ctrl+C)
. (Join-Path $PSScriptRoot "Power.ps1")
