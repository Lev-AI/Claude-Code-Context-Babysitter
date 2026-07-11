#Requires -Version 5.1
<#
.SYNOPSIS
  Install HEAVY experiment: folders, local config, statusLine in Claude settings.

.DESCRIPTION
  One-time setup. Automatically adds the statusLine bridge to
  %USERPROFILE%\.claude\settings.json (with a timestamped backup).
  An existing foreign statusLine is never replaced unless -ForceStatusLine.

.EXAMPLE
  .\Install-Heavy.ps1
  .\Install-Heavy.ps1 -PrintOnly
  .\Install-Heavy.ps1 -ForceStatusLine
#>
[CmdletBinding()]
param(
    [switch] $PrintOnly,
    [switch] $ForceStatusLine,
    [string] $SettingsPath = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\lib\Common.ps1")

$root = Get-ExperimentRoot
$repo = Get-RepoRoot
$statusScript = Join-Path $root "scripts\statusline-bridge.ps1"
$statusFwd = ($statusScript -replace "\\", "/")
$statusCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File $statusFwd"
if (-not $SettingsPath) {
    $SettingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"
}

Write-Host "=== Install HEAVY PowerShell experiment ===" -ForegroundColor Cyan
Write-Host "Experiment: $root"
Write-Host "Repo:       $repo"
Write-Host "Settings:   $SettingsPath"

# Ensure state dirs
@(
    (Join-Path $root ".state"),
    (Join-Path $root ".state\logs"),
    (Join-Path $repo ".session_bridge")
) | ForEach-Object {
    if (-not (Test-Path $_)) {
        if (-not $PrintOnly) {
            New-Item -ItemType Directory -Path $_ -Force | Out-Null
        }
        Write-Host "dir: $_"
    }
}

# Copy heavy config to local if missing
$localCfg = Join-Path $root "config.local.json"
$heavyCfg = Join-Path $root "config.heavy.json"
if (-not (Test-Path $localCfg) -and (Test-Path $heavyCfg) -and -not $PrintOnly) {
    Copy-Item $heavyCfg $localCfg
    Write-Host "Created config.local.json from config.heavy.json"
}

function Write-NoBomFile {
    param([string] $Path, [string] $Text)
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path (Get-Location).Path $Path
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

# --- statusLine into Claude settings.json (automatic, with backup) ---
$statusLineState = "skipped (PrintOnly)"
if (-not $PrintOnly) {
    $settings = $null
    $parseFailed = $false
    if (Test-Path $SettingsPath) {
        try {
            $settings = Get-Content $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            $parseFailed = $true
        }
        if ($null -eq $settings -and -not $parseFailed -and
            ([string](Get-Content $SettingsPath -Raw -Encoding UTF8)).Trim() -ne "") {
            $parseFailed = $true
        }
    }
    if ($parseFailed) {
        Write-Host "WARN: cannot parse $SettingsPath - not touching it. Add statusLine manually (snippet below)." -ForegroundColor Yellow
        $statusLineState = "manual (settings.json unparsable)"
    }
    else {
        if ($null -eq $settings) { $settings = New-Object PSObject }
        $existing = $settings.PSObject.Properties['statusLine']
        $existingCmd = ""
        if ($existing -and $existing.Value) {
            $existingCmd = [string](Get-Prop $existing.Value "command" "")
        }
        if ($existing -and $existingCmd -like "*statusline-bridge.ps1*" -and -not $ForceStatusLine) {
            Write-Host "statusLine already points to the bridge - OK"
            $statusLineState = "already installed"
        }
        elseif ($existing -and -not $ForceStatusLine) {
            Write-Host "statusLine already set to something else - NOT touching (use -ForceStatusLine to replace):" -ForegroundColor Yellow
            Write-Host "  current: $existingCmd"
            $statusLineState = "kept existing (foreign)"
        }
        else {
            if (Test-Path $SettingsPath) {
                $backup = "$SettingsPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
                Copy-Item $SettingsPath $backup
                Write-Host "Backup: $backup"
            }
            else {
                $dir = Split-Path -Parent $SettingsPath
                if (-not (Test-Path $dir)) {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                }
            }
            $sl = [pscustomobject]@{ type = "command"; command = $statusCmd }
            $settings | Add-Member -NotePropertyName statusLine -NotePropertyValue $sl -Force
            Write-NoBomFile -Path $SettingsPath -Text (($settings | ConvertTo-Json -Depth 10) + "`n")
            Write-Host "statusLine written to $SettingsPath" -ForegroundColor Green
            $statusLineState = "installed"
        }
    }
}

# Fallback snippet (manual merge)
$settingsSnippet = @"
"statusLine": {
  "type": "command",
  "command": "$statusCmd"
}
"@
$snippetPath = Join-Path $root ".state\settings-snippet.txt"
if (-not $PrintOnly) {
    Write-NoBomFile -Path $snippetPath -Text $settingsSnippet
}

Write-Host ""
Write-Host "statusLine: $statusLineState (snippet saved: $snippetPath)"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "1) Restart Claude Code; after 1-2 turns the status bar shows '5h NN%'"
Write-Host "   and $repo\.session_bridge\usage.json refreshes."
Write-Host ""
Write-Host "2) Daily one-command start (from your project folder):"
Write-Host "   cd YOUR_PROJECT"
Write-Host "   & `"$root\scripts\Start-Babysitter.ps1`""
Write-Host "   (opens claude -n <folder-name> + watcher + cache pinger)"
Write-Host ""
Write-Host "3) Stop everything:"
Write-Host "   & `"$root\scripts\Stop-HeavyWatch.ps1`""
Write-Host ""
Write-Host "Details: INSTRUCTIONS.md in the experiment folder."
Write-Host "Done."
