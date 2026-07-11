#Requires -Version 5.1
# Reliable Claude launch strategies (relaunch / headless -p), not SendKeys.

. (Join-Path $PSScriptRoot "Common.ps1")

function Build-ContinuePrompt {
    param(
        [string] $BaseMessage,
        [string] $ProjectCwd,
        [string] $SessionName
    )
    $parts = @()
    if ($BaseMessage) { $parts += $BaseMessage.Trim() }
    $parts += "Working directory context: $ProjectCwd"
    if ($SessionName) {
        $parts += "Session name was: $SessionName"
    }
    $progress = Join-Path $ProjectCwd "PROGRESS.md"
    if (Test-Path $progress) {
        $parts += "Re-read PROGRESS.md in the project root and continue the Next steps. Do not re-litigate architecture unless blocked. Prefer autonomous reversible choices."
    }
    else {
        $parts += "If PROGRESS.md exists, re-read it. Proceed autonomously with reversible defaults."
    }
    $parts += "Do not ask optional preference questions. Stop only for secrets, destructive/prod actions, or true blockers."
    return ($parts -join " ")
}

function Invoke-ClaudeContinue {
    <#
    .SYNOPSIS
      Reliable continue: resume session with -p prompt (preferred) or interactive -c.
    #>
    param(
        [string] $ProjectCwd = (Get-Location).Path,
        [string] $ClaudeCommand = "claude",
        [string] $SessionName = "",
        [string] $RetryMessage = "Continue where you left off after the usage limit reset.",
        [ValidateSet("headless", "interactive", "both")]
        [string] $Mode = "headless",
        [switch] $NewWindow,
        [int] $MaxAttempts = 3,
        [int] $RetryDelaySeconds = 20
    )

    if (-not (Test-ClaudeAvailable -ClaudeCommand $ClaudeCommand)) {
        throw "Claude command not on PATH: $ClaudeCommand"
    }
    if (-not (Test-Path $ProjectCwd)) {
        throw "Project cwd does not exist: $ProjectCwd"
    }

    $prompt = Build-ContinuePrompt -BaseMessage $RetryMessage -ProjectCwd $ProjectCwd -SessionName $SessionName
    Write-BridgeLog "Continue prompt length=$($prompt.Length) cwd=$ProjectCwd mode=$Mode session=$SessionName"

    $attempt = 0
    $lastErr = $null
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        Write-BridgeLog "Claude continue attempt $attempt / $MaxAttempts"

        try {
            if ($Mode -eq "headless" -or $Mode -eq "both") {
                $ok = Invoke-ClaudeHeadlessContinue `
                    -ProjectCwd $ProjectCwd `
                    -ClaudeCommand $ClaudeCommand `
                    -SessionName $SessionName `
                    -Prompt $prompt `
                    -NewWindow:$NewWindow
                if ($ok) {
                    Write-BridgeLog "Headless continue launched OK"
                    return [pscustomobject]@{ ok = $true; mode = "headless"; attempt = $attempt }
                }
            }

            if ($Mode -eq "interactive" -or $Mode -eq "both") {
                $ok = Invoke-ClaudeInteractiveContinue `
                    -ProjectCwd $ProjectCwd `
                    -ClaudeCommand $ClaudeCommand `
                    -SessionName $SessionName `
                    -Prompt $prompt `
                    -NewWindow:$true
                if ($ok) {
                    Write-BridgeLog "Interactive continue window launched OK"
                    return [pscustomobject]@{ ok = $true; mode = "interactive"; attempt = $attempt }
                }
            }
        }
        catch {
            $lastErr = $_
            Write-BridgeLog "Continue attempt failed: $_" "WARN"
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    throw "All continue attempts failed. Last error: $lastErr"
}

function Invoke-ClaudeHeadlessContinue {
    param(
        [string] $ProjectCwd,
        [string] $ClaudeCommand,
        [string] $SessionName,
        [string] $Prompt,
        [switch] $NewWindow
    )

    # Prefer named resume for reliability; fall back to --continue
    $argList = New-Object System.Collections.Generic.List[string]
    if ($SessionName) {
        $argList.Add("--resume")
        $argList.Add($SessionName)
    }
    else {
        $argList.Add("-c")
    }
    $argList.Add("-p")
    $argList.Add($Prompt)

    $argString = ($argList | ForEach-Object {
            if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
        }) -join " "

    Write-BridgeLog "Launch: $ClaudeCommand $argString (cwd=$ProjectCwd)"

    if ($NewWindow) {
        $claudeEsc = $ClaudeCommand.Replace("'", "''")
        $psCmd = @"
Set-Location -LiteralPath '$($ProjectCwd.Replace("'","''"))'
Write-Host '=== Session Bridge HEAVY: headless continue ===' -ForegroundColor Cyan
Write-Host 'cwd:' (Get-Location)
& '$claudeEsc' $argString
`$code = `$LASTEXITCODE
Write-Host "claude exit code: `$code"
if (`$code -ne 0) { exit `$code }
"@
        $p = Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $psCmd
        ) -PassThru -WorkingDirectory $ProjectCwd
        Write-BridgeLog "Started process PID=$($p.Id)"
        $exited = $p.WaitForExit(15000)
        if ($exited -and $p.ExitCode -ne 0) {
            Write-BridgeLog "Headless continue window exited early with code $($p.ExitCode)" "WARN"
            return $false
        }
        return $true
    }

    Push-Location -LiteralPath $ProjectCwd
    try {
        & $ClaudeCommand @($argList.ToArray())
        return ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE)
    }
    finally {
        Pop-Location
    }
}

function Invoke-ClaudeInteractiveContinue {
    param(
        [string] $ProjectCwd,
        [string] $ClaudeCommand,
        [string] $SessionName,
        [string] $Prompt,
        [switch] $NewWindow
    )

    $resumeArgs = if ($SessionName) { "--resume `"$SessionName`"" } else { "-c" }
    $escapedPrompt = $Prompt.Replace("'", "''")
    $cwdEsc = $ProjectCwd.Replace("'", "''")

    $psCmd = @"
Set-Location -LiteralPath '$cwdEsc'
Write-Host '=== Session Bridge HEAVY: interactive continue ===' -ForegroundColor Cyan
Write-Host 'If Claude is at a prompt, paste the message below and press Enter.'
Write-Host '---'
Write-Host '$escapedPrompt'
Write-Host '---'
& '$($ClaudeCommand.Replace("'","''"))' $resumeArgs
"@

    if ($NewWindow) {
        Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-NoExit", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $psCmd
        ) -WorkingDirectory $ProjectCwd | Out-Null
        return $true
    }

    Push-Location -LiteralPath $ProjectCwd
    try {
        Write-Host $Prompt
        if ($SessionName) {
            & $ClaudeCommand --resume $SessionName
        }
        else {
            & $ClaudeCommand -c
        }
        return $true
    }
    finally {
        Pop-Location
    }
}
