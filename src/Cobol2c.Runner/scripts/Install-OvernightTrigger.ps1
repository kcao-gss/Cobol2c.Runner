<#
.SYNOPSIS
Registers a SYSTEM scheduled task on the LOCAL controller (GSS-LT-0166) that runs
Run-Unattended.ps1 at a configurable time each night.

SYSTEM tasks run even when the controller is logged off — the laptop must stay powered on
(lid-open or "do nothing on lid close", plugged in).

Run once to install. Re-run to update the schedule. Use -Unregister to remove.

.PARAMETER RunAt   Daily start time in HH:mm format (24-hour). Default: 22:00 (10 PM).
.PARAMETER Ta01Pw  Password for TA01 on the VMs. Set Runner__Ta01Pw env var as an alternative.
.PARAMETER Unregister  Remove the task instead of creating it.
#>
param(
    [string]$RunAt      = '22:00',
    [string]$Ta01Pw     = '',
    [switch]$Unregister
)

#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'

$taskName = 'Cobol2c.Runner_Unattended_Nightly'
$scriptDir = $PSScriptRoot
$runScript = Join-Path $scriptDir 'Run-Unattended.ps1'

if ($Unregister) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Unregistered scheduled task: $taskName" -ForegroundColor Yellow
    return
}

if (-not (Test-Path -LiteralPath $runScript)) {
    throw "Run-Unattended.ps1 not found at: $runScript"
}

# ── Resolve credential for the task's environment ─────────────────────────────
# We store Ta01Pw as an environment variable on the machine so SYSTEM can read it
# without embedding it in the task XML.
$resolvedPw = if ($Ta01Pw) { $Ta01Pw } else { $env:Runner__Ta01Pw }
if ([string]::IsNullOrWhiteSpace($resolvedPw)) {
    Write-Warning ('Ta01Pw not provided and Runner__Ta01Pw env var is not set. ' +
                   'The task will rely on Runner__Ta01Pw being set in the SYSTEM environment.')
}

# ── Task action ────────────────────────────────────────────────────────────────
# pwsh (PowerShell 7) required — scripts use UTF-8 with em-dashes that ps 5.1 mangles.
$pwsh   = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $pwsh) { $pwsh = 'pwsh' }   # rely on PATH if not directly resolvable

$action = New-ScheduledTaskAction `
    -Execute $pwsh `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runScript`"" `
    -WorkingDirectory $scriptDir

# ── Trigger: daily at the configured time ─────────────────────────────────────
$trigger = New-ScheduledTaskTrigger -Daily -At $RunAt

# ── Settings ───────────────────────────────────────────────────────────────────
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit  (New-TimeSpan -Hours 12) `   # hard cap: 12-hour overnight window
    -MultipleInstances   IgnoreNew `                  # no overlap if previous run is late
    -StartWhenAvailable                               # run ASAP if the trigger was missed

# ── Principal: SYSTEM ─────────────────────────────────────────────────────────
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

# ── Register (or update) ───────────────────────────────────────────────────────
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Set-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings | Out-Null
    Write-Host "Updated scheduled task: $taskName  (runs daily at $RunAt)" -ForegroundColor Green
} else {
    Register-ScheduledTask `
        -TaskName  $taskName `
        -Action    $action `
        -Trigger   $trigger `
        -Settings  $settings `
        -Principal $principal `
        -Force | Out-Null
    Write-Host "Registered scheduled task: $taskName  (runs daily at $RunAt)" -ForegroundColor Green
}

Write-Host ''
Write-Host 'IMPORTANT: The controller must remain powered on overnight.' -ForegroundColor Yellow
Write-Host "Task runs as SYSTEM; set Runner__Ta01Pw in the system environment so Run-Unattended.ps1 can read it." -ForegroundColor Yellow
Write-Host ''
Write-Host "To verify:  Get-ScheduledTask -TaskName '$taskName'" -ForegroundColor Gray
Write-Host "To run now: Start-ScheduledTask -TaskName '$taskName'" -ForegroundColor Gray
Write-Host "To remove:  .\Install-OvernightTrigger.ps1 -Unregister" -ForegroundColor Gray
