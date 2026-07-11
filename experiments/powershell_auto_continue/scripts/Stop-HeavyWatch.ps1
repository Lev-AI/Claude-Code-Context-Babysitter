#Requires -Version 5.1
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\lib\Common.ps1")
$stop = Join-Path (Get-ExperimentRoot) ".state\STOP"
New-Item -ItemType File -Path $stop -Force | Out-Null
Write-BridgeLog "Wrote STOP file: $stop"
Write-Host "Stop file created. Watcher and pinger will exit on next poll."
Write-Host "Remove with: Remove-Item `"$stop`""
