<#
.SYNOPSIS
Registers Cobol2c.Agent as a per-user scheduled task that runs at logon of the current user.
/it /rl HIGHEST so the agent can stop GssSystemIntegrityService. No elevation required for registration.

.PARAMETER AgentExe
Full path to Cobol2c.Agent.exe. Defaults to Cobol2c.Agent.exe in the same directory as this script.

.PARAMETER OrchestratorUrl
Base URL of the orchestrator. Passed as Agent:OrchestratorUrl override on the command line.

.PARAMETER ExpectedMachine
Optional: warn (but do not abort) if the current machine name does not match this value.
Set to "TA01" (or the target VM name) to catch accidental runs on the wrong host.
#>
param(
    [string]$AgentExe        = (Join-Path $PSScriptRoot 'Cobol2c.Agent.exe'),
    [string]$OrchestratorUrl = 'http://localhost:5100',
    [string]$ExpectedMachine = 'TA01'
)

$ErrorActionPreference = 'Stop'

# Guard: warn when running on an unexpected machine.
# The agent is designed to run on the TA VM (TA01), not on the controller.
# This is a warning, not an abort -- the operator may intentionally run on another machine.
if ($ExpectedMachine -and $env:COMPUTERNAME -ne $ExpectedMachine) {
    Write-Warning ("Install-AgentTask: running on '$($env:COMPUTERNAME)', expected '$ExpectedMachine'. " +
                   "If this is intentional, pass -ExpectedMachine $($env:COMPUTERNAME) to suppress this warning.")
}

if (-not (Test-Path -LiteralPath $AgentExe)) {
    throw "Agent EXE not found: $AgentExe. Publish first: dotnet publish -r win-x64 -p:SelfContained=true -o <outdir>"
}

$taskName   = 'Cobol2c.Agent'
$workingDir = Split-Path $AgentExe -Parent
$taskArgs   = "--Agent:OrchestratorUrl $OrchestratorUrl"

$action = New-ScheduledTaskAction -Execute $AgentExe -Argument $taskArgs -WorkingDirectory $workingDir

# At logon of the current user; /it = interactive (required for TA GUI automation)
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 8) -MultipleInstances IgnoreNew -StartWhenAvailable

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Registered: $taskName"
Write-Host "  Exe:      $AgentExe"
Write-Host "  Args:     $taskArgs"
Write-Host "  Trigger:  At logon of $($env:USERNAME)"
Write-Host "  RunLevel: Highest (interactive /it)"
Write-Host ''
Write-Host 'To start immediately: Start-ScheduledTask -TaskName Cobol2c.Agent'