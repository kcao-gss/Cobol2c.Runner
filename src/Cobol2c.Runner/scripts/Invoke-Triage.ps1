<#
.SYNOPSIS
Report-only triage entry point. Parses TA HTML logs + CoreLog traces and emits a
TriageResult JSON object to stdout. Called by PowerShellTriageEngine via PowerShellHost.

Phases covered: collect → compare (comparability gate) → trace (crash extraction) → flow-diff.
Routing bisection (isolate/locate/fix) is NOT performed here — report-only scope.

.PARAMETER FailLogDir     Directory of Cobol2C HTML result files (*.html).
.PARAMETER RefLogDir      Directory of reference (SP2V6/Production) HTML result files.
.PARAMETER FailCoreLogPath  Full path to the Cobol2C AutoTrace CoreLog*.glog (empty = logging was off).
.PARAMETER RefCoreLogPath   Full path to the reference AutoTrace CoreLog*.glog (empty = logging was off).
#>
param(
    [string]$FailLogDir,
    [string]$RefLogDir,
    [string]$FailCoreLogPath = '',
    [string]$RefCoreLogPath  = ''
)

$ErrorActionPreference = 'Stop'

# Emit UTF-8 to the redirected pipe so C# reads it correctly on both PS 5.1 and PS 7.
# PS 5.1 defaults to the system code page on redirected output; PS 7 already defaults to UTF-8.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# Import modules from same directory as this script
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptDir 'TaParsing.psm1') -Force
Import-Module (Join-Path $scriptDir 'TaTrace.psm1')   -Force

# Guard: a missing/unmounted dir would silently produce empty results, falsely reporting "no regression".
if (-not (Test-Path -LiteralPath $FailLogDir)) { throw "FailLogDir not found: $FailLogDir" }
if (-not (Test-Path -LiteralPath $RefLogDir))  { throw "RefLogDir not found: $RefLogDir" }

# --- Step 1-2: collect & classify ---
$failResults = @(Get-TcResults -LogDir $FailLogDir)
$refResults  = @(Get-TcResults -LogDir $RefLogDir)

# --- Step 3: comparability gate ---
$gated = Get-ComparableFailed -FailResults $failResults -RefResults $refResults

# Use a List to avoid the O(N²) array reallocation that $findings += causes in a loop.
$findings = [System.Collections.Generic.List[object]]::new()

foreach ($tc in $gated.Comparable) {
    $crash   = $null
    $flowDiv = $null

    # --- Step 4: crash extraction from Cobol2C CoreLog ---
    if ($FailCoreLogPath -and (Test-Path -LiteralPath $FailCoreLogPath)) {
        $crash = Get-CrashSignature -GlogPath $FailCoreLogPath

        # --- Step 5: flow-sequence divergence (only when both logs available) ---
        if ($RefCoreLogPath -and (Test-Path -LiteralPath $RefCoreLogPath)) {
            $flowDiv = Get-FlowDivergence -FailGlog $FailCoreLogPath -RefGlog $RefCoreLogPath
        }
    }

    $findings.Add([pscustomobject]@{
        TC             = $tc.TC
        Comparable     = $true
        Crash          = $crash
        FlowDivergence = $flowDiv
    })
}

# Emit single JSON object to stdout — deserialized by PowerShellHost.RunScriptAsync<TriageResult>
[pscustomobject]@{
    HasRegressions     = ($findings.Count -gt 0)
    ComparableCount    = $gated.Comparable.Count
    NotComparableCount = $gated.NotComparable.Count
    Findings           = @($findings)   # @() ensures a JSON array even when Count = 1
} | ConvertTo-Json -Depth 10
