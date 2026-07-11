#Requires -Version 5.1
<#
.SYNOPSIS
  Write usage.json for session_bridge + this experiment (E1/E2 signal).

.EXAMPLE
  .\Register-Usage.ps1 -Percent 100 -RateLimited -ResetAt "17:00"
  .\Register-Usage.ps1 -Percent 92
  .\Register-Usage.ps1 -Percent 100 -RateLimited -ResetAt "2026-07-10T17:00:00"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 100)]
    [double] $Percent = 100,

    [switch] $RateLimited,

    [string] $ResetAt = "",

    [string] $UsageFile = ""
)

$ErrorActionPreference = "Stop"

function Resolve-UsagePath {
    param([string] $Path)
    if ($Path) { return $Path }
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
    return (Join-Path $repoRoot ".session_bridge\usage.json")
}

function Parse-ResetAt {
    param([string] $Value)
    if (-not $Value) { return $null }
    # Today + HH:mm
    if ($Value -match '^\d{1,2}:\d{2}$') {
        $today = Get-Date -Format "yyyy-MM-dd"
        $dt = [datetime]::Parse("$today $Value")
        if (((Get-Date) - $dt).TotalSeconds -gt 120) {
            $dt = $dt.AddDays(1)
        }
        return $dt.ToString("o")
    }
    return ([datetime]::Parse($Value)).ToString("o")
}

$path = Resolve-UsagePath -Path $UsageFile
if (-not [System.IO.Path]::IsPathRooted($path)) {
    $path = Join-Path (Get-Location).Path $path
}
$dir = Split-Path -Parent $path
if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$payload = [ordered]@{
    session_usage_percent = $Percent
    rate_limited          = [bool]$RateLimited
    updated_at            = (Get-Date).ToUniversalTime().ToString("o")
    source                = "powershell_experiment"
}

$resetIso = Parse-ResetAt -Value $ResetAt
if ($resetIso) {
    $payload["reset_at"] = $resetIso
}

$json = $payload | ConvertTo-Json -Depth 5
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($path, $json, $utf8NoBom)
Write-Host "Wrote $path"
Write-Host $json
