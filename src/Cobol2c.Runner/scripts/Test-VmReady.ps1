<#
.SYNOPSIS
Lightweight VM readiness probe. Calls Assert-VmReady and emits a JSON result to stdout.
Used by MachineSelector.cs to pick available machines before a confirmation batch run.

.PARAMETER Machine   VM name, e.g. "TGFTA-118"
.PARAMETER Ta01Pw    TA01 account password (same credential as Invoke-TaRun.ps1)
#>
param(
    [string]$Machine,
    [string]$Ta01Pw
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$scriptDir = $PSScriptRoot
Import-Module (Join-Path $scriptDir 'TaRemote.psm1') -Force

try {
    Assert-VmReady -Machine $Machine -Ta01Pw $Ta01Pw
    [pscustomobject]@{ Ready = $true; Reason = $null } | ConvertTo-Json -Compress
}
catch {
    # Not ready - emit structured failure so the C# caller can log the reason
    [pscustomobject]@{ Ready = $false; Reason = $_.Exception.Message } | ConvertTo-Json -Compress
}
