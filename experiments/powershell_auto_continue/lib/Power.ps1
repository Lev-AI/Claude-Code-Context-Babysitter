#Requires -Version 5.1
# Win32 power / console helpers:
#   - prevent-sleep (experiments/sleep_putch.md, option 2): SetThreadExecutionState
#     keeps the OS from idle auto-sleep while watcher/pinger/wait are running.
#   - soft-stop (experiments/limit_detection_and_stop.md, Proposal A): deliver
#     Ctrl+C to the console of a recorded Claude window PID.
# Dot-sourced by Common.ps1 - relies on Write-BridgeLog / Get-Prop being defined.

# Tracks the ES_* flags this process currently holds, only to avoid re-logging
# on every re-assert. The OS clears thread execution state on process exit.
$script:BridgePreventSleepFlags = $null

function Initialize-BridgePowerType {
    if ('SessionBridge.Power' -as [type]) { return }
    Add-Type -Namespace SessionBridge -Name Power -MemberDefinition @"
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
"@
}

function Get-BridgePowerConfig {
    param($Config)
    $p = Get-Prop $Config "power"
    return [pscustomobject]@{
        prevent_sleep   = [bool](Get-Prop $p "prevent_sleep" $false)
        scope           = [string](Get-Prop $p "prevent_sleep_scope" "babysitter")
        keep_display_on = [bool](Get-Prop $p "keep_display_on" $false)
    }
}

function Test-BridgePowerScope {
    <#
      Which component should hold prevent-sleep for a given configured scope:
        babysitter / all_children -> watcher, pinger and the continue wait
        watcher                   -> watcher (and its in-process continue wait)
        pinger                    -> pinger only
        wait_only                 -> only Invoke-HeavyContinue's waiting phase
    #>
    param(
        [Parameter(Mandatory)] $Power,
        [Parameter(Mandatory)][ValidateSet("watcher", "pinger", "wait")]
        [string] $Component
    )
    if (-not $Power.prevent_sleep) { return $false }
    switch ($Power.scope) {
        "babysitter"   { return $true }
        "all_children" { return $true }
        "watcher"      { return ($Component -in @("watcher", "wait")) }
        "pinger"       { return ($Component -eq "pinger") }
        "wait_only"    { return ($Component -eq "wait") }
        default {
            Write-BridgeLog "Unknown prevent_sleep_scope '$($Power.scope)' - prevent-sleep off" "WARN"
            return $false
        }
    }
}

function Enable-BridgePreventSleep {
    <#
      ES_CONTINUOUS | ES_SYSTEM_REQUIRED: block idle auto-sleep while this
      thread lives; the display may still turn off (unless -KeepDisplayOn).
      Safe to call every poll tick - logs only when the held state changes.
    #>
    param([switch] $KeepDisplayOn)
    Initialize-BridgePowerType
    $flags = [uint32]"0x80000001"                            # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
    if ($KeepDisplayOn) { $flags = $flags -bor [uint32]2 }   # ES_DISPLAY_REQUIRED
    $prev = [SessionBridge.Power]::SetThreadExecutionState($flags)
    if ($prev -eq 0) {
        Write-BridgeLog ("prevent_sleep: SetThreadExecutionState(0x{0}) failed" -f $flags.ToString("X8")) "WARN"
        return $false
    }
    if ($script:BridgePreventSleepFlags -ne $flags) {
        Write-BridgeLog ("prevent_sleep enabled (flags=0x{0} keep_display_on={1})" -f $flags.ToString("X8"), [bool]$KeepDisplayOn)
        $script:BridgePreventSleepFlags = $flags
    }
    return $true
}

function Disable-BridgePreventSleep {
    # ES_CONTINUOUS alone clears the continuous flags for this thread
    if (-not ('SessionBridge.Power' -as [type])) { return }
    [void][SessionBridge.Power]::SetThreadExecutionState([uint32]"0x80000000")
    if ($script:BridgePreventSleepFlags) {
        Write-BridgeLog "prevent_sleep disabled (normal OS power behavior restored)"
    }
    $script:BridgePreventSleepFlags = $null
}

function Send-ConsoleCtrlC {
    <#
      Delivers Ctrl+C to every process attached to the console of $TargetPid
      (for a `powershell -NoExit -Command claude ...` window that is the shell
      host and the claude child; a single Ctrl+C interrupts the current turn
      and leaves the window open).

      Uses a short-lived hidden helper process for AttachConsole +
      GenerateConsoleCtrlEvent, so this process's own console is untouched.
      Returns $true when the event was sent.
    #>
    param([Parameter(Mandatory)][int] $TargetPid)

    $template = @'
$ErrorActionPreference = "Stop"
try {
    $sig = '[DllImport("kernel32.dll", SetLastError = true)] public static extern bool FreeConsole(); [DllImport("kernel32.dll", SetLastError = true)] public static extern bool AttachConsole(uint dwProcessId); [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add); [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);'
    Add-Type -Namespace SessionBridge -Name ConsoleCtrl -MemberDefinition $sig
    [void][SessionBridge.ConsoleCtrl]::FreeConsole()
    if (-not [SessionBridge.ConsoleCtrl]::AttachConsole([uint32]__TARGET_PID__)) { exit 2 }
    # Ignore the Ctrl+C in this helper itself (it is attached to the same console)
    [void][SessionBridge.ConsoleCtrl]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)
    if (-not [SessionBridge.ConsoleCtrl]::GenerateConsoleCtrlEvent(0, 0)) { exit 3 }
    Start-Sleep -Milliseconds 400
    exit 0
}
catch { exit 4 }
'@
    $src = $template.Replace('__TARGET_PID__', [string]$TargetPid)
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($src))
    try {
        $p = Start-Process -FilePath "powershell.exe" -ArgumentList @(
            "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $enc
        ) -WindowStyle Hidden -PassThru
    }
    catch {
        Write-BridgeLog "Ctrl+C helper failed to start: $_" "WARN"
        return $false
    }
    if (-not $p.WaitForExit(15000)) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
        Write-BridgeLog "Ctrl+C helper timed out" "WARN"
        return $false
    }
    if ($p.ExitCode -eq 0) { return $true }
    Write-BridgeLog "Ctrl+C helper exit=$($p.ExitCode) (2=AttachConsole failed, 3=GenerateConsoleCtrlEvent failed)" "WARN"
    return $false
}
