# Set-VmNoLock.ps1
# Per-run provisioning: prevent the VM from locking / blanking the console session during a
# multi-hour overnight run. Pushes three settings to the remote VM via a SYSTEM scheduled task:
#   1. InactivityTimeoutSecs = 0  (disables idle lock via policy registry key)
#   2. Screensaver disabled       (ScreenSaveActive = 0, ScreenSaveTimeOut = 0)
#   3. Power/monitor sleep = Never (powercfg)
#
# Must be called from the controller; uses C$ + schtasks /s to reach the VM.
# Idempotent — safe to run before every suite.

param(
    [Parameter(Mandatory)][string]$Machine,
    [Parameter(Mandatory)][string]$Ta01Pw
)

$ErrorActionPreference = 'Stop'

$winUser     = "$Machine\TA01"
$taskName    = 'Cobol2c_NoLock'
$cDollar     = "\\$Machine\C$"
$scriptDest  = 'C:\Windows\Temp\set-nolock.ps1'

# ── Inline script that runs on the VM as SYSTEM ────────────────────────────────
# Written as a here-string so it lands verbatim; no UNC path inside so no backslash hazard.
$vmScript = @'
$ErrorActionPreference = 'SilentlyContinue'
$log = 'C:\Windows\Temp\nolock.log'
"=== set-nolock $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Set-Content -LiteralPath $log

# 1) Idle lock timeout (policy key — 0 = never)
$sysKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Set-ItemProperty -Path $sysKey -Name 'InactivityTimeoutSecs' -Value 0 -Type DWord -Force
"InactivityTimeoutSecs -> $((Get-ItemProperty $sysKey).InactivityTimeoutSecs)" | Out-File $log -Append

# 2) Screensaver — disable for the machine (HKLM default user hive fallback not needed;
#    TA01 auto-logon means its profile is loaded into HKCU when session is active)
$cuKey = 'HKCU:\Control Panel\Desktop'
if (Test-Path $cuKey) {
    Set-ItemProperty -Path $cuKey -Name 'ScreenSaveActive'  -Value '0' -Force
    Set-ItemProperty -Path $cuKey -Name 'ScreenSaveTimeOut' -Value '0' -Force
    "Screensaver disabled in HKCU" | Out-File $log -Append
} else {
    "HKCU\Control Panel\Desktop not accessible as SYSTEM — skipped" | Out-File $log -Append
}

# 3) Power: disable monitor sleep and standby (so the console session keeps rendering)
$pfOut = (powercfg /change monitor-timeout-ac 0 2>&1)
"powercfg monitor-timeout -> $pfOut exit=$LASTEXITCODE" | Out-File $log -Append
$pfOut2 = (powercfg /change standby-timeout-ac 0 2>&1)
"powercfg standby-timeout -> $pfOut2 exit=$LASTEXITCODE" | Out-File $log -Append

"=== done ===" | Out-File $log -Append
'@

# ── Deploy the inline script to the VM via C$ ──────────────────────────────────
$r = & cmd /c "net use `"$cDollar`" /user:`"$winUser`" `"$Ta01Pw`"" 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Set-VmNoLock: net use C$ failed on $Machine (exit $LASTEXITCODE): $($r -join ' ')"
}

try {
    Set-Content -LiteralPath "\\$Machine\C$\Windows\Temp\set-nolock.ps1" -Value $vmScript -Encoding Ascii
} catch {
    & cmd /c "net use `"$cDollar`" /delete" 2>&1 | Out-Null
    throw ("Set-VmNoLock: failed to copy set-nolock.ps1 to " + $Machine + " C`$: " + $_)
}

# ── Run as SYSTEM via schtasks ─────────────────────────────────────────────────
& cmd /c "schtasks /delete /s `"$Machine`" /u `"$winUser`" /p `"$Ta01Pw`" /tn `"$taskName`" /f" 2>&1 | Out-Null

$noLockCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\set-nolock.ps1"
$create = & cmd /c ("schtasks /create /s `"$Machine`" /u `"$winUser`" /p `"$Ta01Pw`"" +
                     " /tn `"$taskName`" /tr `"$noLockCmd`"" +
                     " /sc ONCE /st 23:59 /ru SYSTEM /rl HIGHEST /f") 2>&1
if ($LASTEXITCODE -ne 0) {
    & cmd /c "net use `"$cDollar`" /delete" 2>&1 | Out-Null
    throw "Set-VmNoLock: schtasks /create failed on $Machine (exit $LASTEXITCODE): $($create -join ' ')"
}

$run = & cmd /c "schtasks /run /s `"$Machine`" /u `"$winUser`" /p `"$Ta01Pw`" /tn `"$taskName`"" 2>&1
if ($LASTEXITCODE -ne 0) {
    & cmd /c "net use `"$cDollar`" /delete" 2>&1 | Out-Null
    throw "Set-VmNoLock: schtasks /run failed on $Machine (exit $LASTEXITCODE): $($run -join ' ')"
}

Start-Sleep -Seconds 8   # let the script run before we clean up

# ── Clean up ───────────────────────────────────────────────────────────────────
& cmd /c "schtasks /delete /s `"$Machine`" /u `"$winUser`" /p `"$Ta01Pw`" /tn `"$taskName`" /f" 2>&1 | Out-Null
& cmd /c "net use `"$cDollar`" /delete" 2>&1 | Out-Null

Write-Host "Set-VmNoLock: applied no-lock settings on $Machine." -ForegroundColor Green
