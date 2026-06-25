<#
.SYNOPSIS
One-off diagnostic: push a network-connectivity probe to a VM via schtasks /s and read
results back from TAShare. Runs as TA01 with /it (interactive session) — the exact same
context as ta execute — so the TCP results reflect what ta execute would see.

.PARAMETER Machine    VM name, e.g. "TGFTA-119"

Ta01Pw is read from $env:Runner__Ta01Pw (same as the runner — do NOT pass as an arg).
#>
param([string]$Machine = 'TGFTA-119')

$ErrorActionPreference = 'Stop'

$Ta01Pw = $env:Runner__Ta01Pw
if ([string]::IsNullOrWhiteSpace($Ta01Pw)) {
    throw 'Set Runner__Ta01Pw env var (the TA01 account password) before running this script.'
}

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptDir 'TaRemote.psm1') -Force

$ProbeDir   = "\\gss2k19rnd.gss.local\TAShare\Cobol2C\Logs\$Machine\netprobe"
$taskName   = "Cobol2c.Probe_$([datetime]::UtcNow.ToString('HHmmss'))"
$localBat   = Join-Path $env:TEMP 'netprobe.bat'

# ── Generate the probe batch ────────────────────────────────────────────────
$bat = @"
@echo off
set PROBE_DIR=\\gss2k19rnd.gss.local\TAShare\Cobol2C\Logs\$Machine\netprobe
if not exist "%PROBE_DIR%" mkdir "%PROBE_DIR%"
set OUT=%PROBE_DIR%\probe.txt

echo === WHOAMI === > "%OUT%"
whoami >> "%OUT%" 2>&1

echo. >> "%OUT%"
echo === IPCONFIG /ALL === >> "%OUT%"
ipconfig /all >> "%OUT%" 2>&1

echo. >> "%OUT%"
echo === ROUTE PRINT === >> "%OUT%"
route print >> "%OUT%" 2>&1

echo. >> "%OUT%"
echo === TCP TEST: RS 172.16.43.66:53400 (TA repository server) === >> "%OUT%"
powershell -NoProfile -Command "Test-NetConnection 172.16.43.66 -Port 53400 -WarningAction SilentlyContinue | Select-Object ComputerName,RemotePort,TcpTestSucceeded | Format-List" >> "%OUT%" 2>&1

echo. >> "%OUT%"
echo === TCP TEST: LS 172.16.43.66:8778 (TA license server) === >> "%OUT%"
powershell -NoProfile -Command "Test-NetConnection 172.16.43.66 -Port 8778 -WarningAction SilentlyContinue | Select-Object ComputerName,RemotePort,TcpTestSucceeded | Format-List" >> "%OUT%" 2>&1

echo. >> "%OUT%"
echo === TCP TEST: TAShare 172.16.43.178:445 (control - known good) === >> "%OUT%"
powershell -NoProfile -Command "Test-NetConnection 172.16.43.178 -Port 445 -WarningAction SilentlyContinue | Select-Object ComputerName,RemotePort,TcpTestSucceeded | Format-List" >> "%OUT%" 2>&1

echo. >> "%OUT%"
echo === TRACERT to 172.16.43.66 === >> "%OUT%"
tracert -d -h 8 -w 1000 172.16.43.66 >> "%OUT%" 2>&1

echo. >> "%OUT%"
echo === NSLOOKUP 172.16.43.66 === >> "%OUT%"
nslookup 172.16.43.66 >> "%OUT%" 2>&1

echo. >> "%OUT%"
echo === PROBE COMPLETE === >> "%OUT%"
type nul > "%PROBE_DIR%\probe-done.txt"
"@

Set-Content -Path $localBat -Value $bat -Encoding Ascii

# Ensure the probe output dir exists on TAShare so the batch can write into it
$null = New-Item -ItemType Directory -Force -Path $ProbeDir
# Clear any previous probe results
Remove-Item -LiteralPath (Join-Path $ProbeDir 'probe.txt')       -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $ProbeDir 'probe-done.txt')  -Force -ErrorAction SilentlyContinue

Write-Host "Pushing probe to $Machine as task '$taskName' …"

try {
    Connect-VmShare  -Machine $Machine -Ta01Pw $Ta01Pw
    Copy-BatToVm     -Machine $Machine -BatPath $localBat
    Invoke-RemoteTask -Machine $Machine -Ta01Pw $Ta01Pw -TaskName $taskName -BatPath 'C:\Apps\TA-CMD\netprobe.bat'

    # ── Poll for probe-done.txt (timeout 5 min) ─────────────────────────────
    $donePath = Join-Path $ProbeDir 'probe-done.txt'
    $deadline  = (Get-Date).AddMinutes(5)
    Write-Host 'Polling for probe-done.txt …'
    while (-not (Test-Path -LiteralPath $donePath)) {
        if ((Get-Date) -gt $deadline) {
            throw "Probe timed out after 5 min — probe-done.txt never appeared in $ProbeDir"
        }
        Start-Sleep -Seconds 5
        Write-Host '  … waiting'
    }
    Write-Host 'Probe complete. Results:'
    Write-Host ('─' * 72)
    Get-Content -LiteralPath (Join-Path $ProbeDir 'probe.txt') | Write-Host
    Write-Host ('─' * 72)
} finally {
    Remove-RemoteTask -Machine $Machine -Ta01Pw $Ta01Pw -TaskName $taskName
    Remove-Item -LiteralPath $localBat -Force -ErrorAction SilentlyContinue
}
