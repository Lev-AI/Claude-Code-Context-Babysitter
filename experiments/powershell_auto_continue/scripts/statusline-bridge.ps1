#Requires -Version 5.1
<#
.SYNOPSIS
  Optimal Windows statusLine bridge: rate_limits.five_hour -> usage.json

.DESCRIPTION
  Point Claude Code settings at this script (forward slashes in path):

  "statusLine": {
    "type": "command",
    "command": "powershell -NoProfile -File C:/Users/YOU/.../statusline-bridge.ps1"
  }

  Writes ../../../.session_bridge/usage.json relative to this script by default,
  or set env SESSION_BRIDGE_USAGE_FILE.
#>

$ErrorActionPreference = "SilentlyContinue"

$raw = [Console]::In.ReadToEnd()
if (-not $raw) {
    Write-Output "session_bridge"
    exit 0
}

try {
    $data = $raw | ConvertFrom-Json
} catch {
    Write-Output "session_bridge (bad json)"
    exit 0
}

$usagePath = $env:SESSION_BRIDGE_USAGE_FILE
if (-not $usagePath) {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
    $usagePath = Join-Path $repoRoot ".session_bridge\usage.json"
}
if (-not [System.IO.Path]::IsPathRooted($usagePath)) {
    $usagePath = Join-Path (Get-Location).Path $usagePath
}

$dir = Split-Path -Parent $usagePath
if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$five = $null
$resetUnix = $null
$rateLimited = $false

if ($data.rate_limits -and $data.rate_limits.five_hour) {
    $fh = $data.rate_limits.five_hour
    if ($null -ne $fh.used_percentage) {
        # A real percentage is a finite number in 0..100. Claude Code sometimes
        # emits a unix epoch here for an empty 5h window (mirrors resets_at),
        # which would sail past our 99.5 limit and force a false LIMIT/continue.
        # Discard anything out of range so only genuine usage sets $five.
        # See anthropics/claude-code#52326.
        $pct = $fh.used_percentage -as [double]
        if ($null -ne $pct -and -not [double]::IsNaN($pct) -and -not [double]::IsInfinity($pct) -and $pct -ge 0 -and $pct -le 100) {
            $five = $pct
        }
    }
    if ($null -ne $fh.resets_at) {
        $resetUnix = [double]$fh.resets_at
    }
}

$ctx = $null
if ($data.context_window -and $null -ne $data.context_window.used_percentage) {
    $ctx = [double]$data.context_window.used_percentage
}

# Near-hard limit: treat as limited so watcher can schedule continue
if ($null -ne $five -and $five -ge 99.5) {
    $rateLimited = $true
}

$payload = [ordered]@{
    source       = "statusline"
    updated_at   = (Get-Date).ToUniversalTime().ToString("o")
    rate_limited = $rateLimited
}

if ($null -ne $five) {
    $payload["session_usage_percent"] = $five
}
if ($null -ne $ctx) {
    $payload["context_percent"] = $ctx
}
if ($null -ne $resetUnix) {
    # Unix epoch seconds -> ISO local-aware UTC
    $epoch = [DateTimeOffset]::FromUnixTimeSeconds([int64]$resetUnix)
    $payload["reset_at"] = $epoch.UtcDateTime.ToString("o")
}
if ($data.model -and $data.model.display_name) {
    $payload["model"] = [string]$data.model.display_name
}
if ($data.session_id) {
    $payload["session_id"] = [string]$data.session_id
}

$json = $payload | ConvertTo-Json -Compress
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($usagePath, $json, $utf8NoBom)

# Status line text
$parts = @()
if ($payload.model) { $parts += $payload.model }
if ($null -ne $five) { $parts += ("5h {0:N0}%" -f $five) }
elseif ($null -ne $ctx) { $parts += ("ctx {0:N0}%" -f $ctx) }
if ($rateLimited) { $parts += "LIMIT" }

if ($parts.Count -gt 0) {
    Write-Output ($parts -join " | ")
} else {
    Write-Output "session_bridge"
}
