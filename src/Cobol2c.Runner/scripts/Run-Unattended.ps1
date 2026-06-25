<#
.SYNOPSIS
Overnight unattended test entry point — reads unattended-vms.json, self-provisions each VM,
runs the configured suite headlessly, harvests results, and writes a per-run summary.

Designed to be triggered by Install-OvernightTrigger.ps1 as a SYSTEM scheduled task on the
local controller. The controller must stay powered on (lid-open, plugged in).

Each VM is isolated in its own try/catch: a failure on one VM is logged and execution continues
to the next VM. The per-run summary JSON + human-readable matrix are written to the run's output
directory once all VMs are processed.

Ownership sanity-check: before claiming a VM, the script queries the VM's process list for an
active 'ta execute' invocation owned by a different user (the ta-knguyen lesson). If found,
the VM is skipped and logged.

Requires:
  - Runner__Ta01Pw environment variable OR -Ta01Pw parameter.
  - VPN / GSS network access.
  - console-park.ps1 next to this script (deployed to the VM by Enter-ConsoleSession).
  - unattended-vms.json next to this script.
#>
param(
    [string]$ConfigPath = '',    # override for unattended-vms.json path
    [string]$Ta01Pw     = '',    # override; falls back to Runner__Ta01Pw env var
    [string]$OutputDir  = ''     # override for summary output directory
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$scriptDir = $PSScriptRoot

# ── Resolve credential ─────────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($Ta01Pw)) {
    $Ta01Pw = $env:Runner__Ta01Pw
}
if ([string]::IsNullOrWhiteSpace($Ta01Pw)) {
    throw ('Ta01Pw is required. Set the Runner__Ta01Pw environment variable or pass -Ta01Pw.')
}

# ── Load config ────────────────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptDir 'unattended-vms.json'
}
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "unattended-vms.json not found at: $ConfigPath"
}
$cfg     = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$suite   = $cfg.suite
$logging = if ($cfg.logging) { 'true' } else { 'false' }
$vms     = @($cfg.vms)
$tcList  = @($cfg.tcs)

Write-Host "=== Run-Unattended started at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" -ForegroundColor Cyan
Write-Host "Suite: $suite   Logging: $logging   VMs: $($vms -join ', ')   TCs: $($tcList -join ', ')" -ForegroundColor Cyan

# ── Import modules ─────────────────────────────────────────────────────────────
Import-Module (Join-Path $scriptDir 'TaRemote.psm1')   -Force
Import-Module (Join-Path $scriptDir 'TaRecovery.psm1') -Force

# ── Dot-source Invoke-TaRun.ps1 to get Invoke-SuiteRun / New-TABatch ──────────
# The InvocationName='.' guard inside it prevents the run tail from executing.
# $Machine is a script-scope variable set during dot-source; Invoke-SuiteRun reads
# it via dynamic scoping (no -Machine param). We update $Machine per-VM in the loop.
. (Join-Path $scriptDir 'Invoke-TaRun.ps1') `
    -Suite $suite -Machine '__DOT_SOURCE__' -Tcs ($tcList -join ',') `
    -Ta01Pw $Ta01Pw -AutoRecover 'true' -Headless

# ── Resolve TC manifest entries ────────────────────────────────────────────────
$manifestPath = Join-Path $scriptDir 'tc-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "tc-manifest.json not found at: $manifestPath"
}
$manifestMap = @{}
(Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json) |
    ForEach-Object { $manifestMap[$_.tc] = $_ }

$suiteTests = @(foreach ($tc in $tcList) {
    if (-not $manifestMap.ContainsKey($tc)) {
        throw "TC $tc not found in tc-manifest.json. Add it ({tc, rep, prj, path})."
    }
    $manifestMap[$tc]
})

# ── TAShare paths (suite-level bases) ─────────────────────────────────────────
$FailBase = "\\gss2k19rnd.gss.local\TAShare\$suite"
$RefBase  = "\\gss2k19rnd.gss.local\TAShare\SP2V6"

# ── Output directory ───────────────────────────────────────────────────────────
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $uid = [guid]::NewGuid().ToString('N').Substring(0, 6)
    $OutputDir = Join-Path $env:TEMP "Cobol2c_Unattended_${ts}_${uid}"
}
$null = New-Item -ItemType Directory -Force -Path $OutputDir

# ── Helper: read one TC's verdict from a mapped TAShare drive ─────────────────
# Defined here (above the VM loop) so it is in the function table before it is called.
function Get-TcVerdict ([string]$DriveLetter, [string]$Suite, [string]$VMName, [string]$Tc) {
    $dir   = "${DriveLetter}:\${Suite}\Logs\${VMName}"
    $files = try { [System.IO.Directory]::GetFiles($dir) } catch { @() }
    $html  = $files | Where-Object {
        [IO.Path]::GetExtension($_) -eq '.html' -and
        ([IO.Path]::GetFileName($_)) -match "^$Tc[_ ]"
    } | Select-Object -First 1

    if (-not $html) { return 'NO-HTML' }

    $txt     = [System.IO.File]::ReadAllText($html)
    $passNum = if ($txt -match 'Passed:&nbsp;(\d+)') { [int]$matches[1] } else { -1 }
    $failNum = if ($txt -match 'Failed:&nbsp;(\d+)') { [int]$matches[1] } else { -1 }
    if ($passNum -ge 1)                       { return 'PASS' }
    if ($passNum -eq 0 -and $failNum -eq 0)   { return 'NOT-FINISHED' }
    return 'FAIL'
}

# ── Per-VM result accumulator ──────────────────────────────────────────────────
$vmResults = [System.Collections.Generic.List[object]]::new()

foreach ($vm in $vms) {
    Write-Host "`n--- Processing $vm ---" -ForegroundColor Yellow

    # Update the script-scope $Machine that Invoke-SuiteRun reads via dynamic scoping.
    # Invoke-SuiteRun has no -Machine param; it captures $Machine from the enclosing scope
    # at the time it was dot-sourced. Setting it here keeps it in sync per VM.
    $Machine = $vm

    $vmEntry = [pscustomobject]@{
        VM       = $vm
        Status   = 'pending'
        Error    = $null
        TcMatrix = @()
        FailLog  = $null
        RefLog   = $null
    }

    # ── Ownership sanity-check ─────────────────────────────────────────────────
    # Query running processes on the VM; skip if another user's 'ta execute' is active.
    # Uses a $busy flag + break so the inner proc loop does not accidentally continue
    # the outer VM loop.
    $busy = $false
    try {
        $taProcs = @(Get-CimInstance -ComputerName $vm -ClassName Win32_Process `
                                      -Filter "name='ta.exe' OR name='ta execute.exe'" `
                                      -ErrorAction SilentlyContinue |
                     Where-Object { $_.CommandLine -match 'execute' })
        foreach ($proc in $taProcs) {
            $owner = (Invoke-CimMethod -InputObject $proc -MethodName GetOwner `
                                       -ErrorAction SilentlyContinue).User
            if ($owner -and $owner -notmatch '(?i)ta01') {
                Write-Warning ("  " + $vm + ": active 'ta execute' owned by '$owner' - skipping to avoid conflict.")
                $vmEntry.Status = 'skipped-busy'
                $vmEntry.Error  = "ta execute active under user: $owner"
                $busy = $true
                break   # exit the proc loop; outer check handles VM skip
            }
        }
    } catch {
        Write-Warning ("  " + $vm + ": ownership check failed (non-fatal): " + $_)
    }

    if ($busy) {
        $vmResults.Add($vmEntry)
        continue   # skip to next VM
    }

    try {
        # ── Self-provision ─────────────────────────────────────────────────────
        Write-Host ("  " + $vm + ": running Assert-VmReady ...") -ForegroundColor Gray
        Assert-VmReady -Machine $vm -Ta01Pw $Ta01Pw

        Write-Host ("  " + $vm + ": running Set-VmNoLock ...") -ForegroundColor Gray
        & (Join-Path $scriptDir 'Set-VmNoLock.ps1') -Machine $vm -Ta01Pw $Ta01Pw

        Write-Host ("  " + $vm + ": running Enter-ConsoleSession ...") -ForegroundColor Gray
        $parked = Enter-ConsoleSession -Machine $vm -Ta01Pw $Ta01Pw
        if (-not $parked) {
            throw "Console park failed on $vm — park.log did not confirm exit=0. Skipping run."
        }
        Write-Host ("  " + $vm + ": console session parked successfully.") -ForegroundColor Green

        # ── Suite run ──────────────────────────────────────────────────────────
        $failLogDir = "\\gss2k19rnd.gss.local\TAShare\$suite\Logs\$vm"
        $refLogDir  = "\\gss2k19rnd.gss.local\TAShare\SP2V6\Logs\$vm"

        $failBat = "${vm}_${suite}_${ts}_a0.bat"
        $refBat  = "${vm}_SP2V6_${ts}_a0.bat"

        Write-Host ("  " + $vm + ": launching " + $suite + " suite (" + $suiteTests.Count + " TCs) ...") -ForegroundColor Gray
        $failRun = Invoke-SuiteRun -Base $FailBase -SuiteName $suite -BatName $failBat `
                                    -Tests $suiteTests -HtmlDir $failLogDir -ClearLogs $true `
                                    -RecoveryEnabled 'true' -Headless

        Write-Host ("  " + $vm + ": launching SP2V6 reference suite ...") -ForegroundColor Gray
        $refRun  = Invoke-SuiteRun -Base $RefBase -SuiteName 'SP2V6' -BatName $refBat `
                                    -Tests $suiteTests -HtmlDir $refLogDir -ClearLogs $true `
                                    -RecoveryEnabled 'true' -Headless

        # ── Harvest results via mapped drive ───────────────────────────────────
        # Map a drive letter to TAShare to avoid flaky UNC dir enumeration.
        $driveLetter = $null
        foreach ($letter in ('Y','X','W','V','U')) {
            if (-not (Get-PSDrive $letter -ErrorAction SilentlyContinue)) {
                $driveLetter = $letter; break
            }
        }
        $tcMatrix = @()
        if ($driveLetter) {
            & cmd /c "net use ${driveLetter}: `"\\gss2k19rnd.gss.local\TAShare`"" 2>&1 | Out-Null

            foreach ($tc in $tcList) {
                $failVerdict = Get-TcVerdict -DriveLetter $driveLetter -Suite $suite -VMName $vm -Tc $tc
                $refVerdict  = Get-TcVerdict -DriveLetter $driveLetter -Suite 'SP2V6' -VMName $vm -Tc $tc
                $tcMatrix   += [pscustomobject]@{
                    tc   = $tc
                    fail = $failVerdict
                    ref  = $refVerdict
                }
            }

            & cmd /c "net use ${driveLetter}: /delete" 2>&1 | Out-Null
        } else {
            Write-Warning ("  " + $vm + ": no free drive letter found for TAShare mapping - skipping harvest.")
        }

        $vmEntry.Status   = 'completed'
        $vmEntry.TcMatrix = $tcMatrix
        $vmEntry.FailLog  = $failRun.LogDir
        $vmEntry.RefLog   = $refRun.LogDir

    } catch {
        Write-Warning ("  " + $vm + ": FAILED - " + $_.Exception.Message)
        $vmEntry.Status = 'failed'
        $vmEntry.Error  = $_.Exception.Message
    }

    $vmResults.Add($vmEntry)   # exactly one Add per VM (busy path adds+continues above)
}

# ── Write summary JSON ─────────────────────────────────────────────────────────
$summary = [pscustomobject]@{
    RunAt   = (Get-Date -Format 'o')
    Suite   = $suite
    Tcs     = $tcList
    VMs     = @($vmResults)
}
$jsonPath = Join-Path $OutputDir "summary_${ts}.json"
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding utf8
Write-Host "`nSummary JSON: $jsonPath" -ForegroundColor Cyan

# ── Write human-readable matrix ────────────────────────────────────────────────
$matrixPath = Join-Path $OutputDir "matrix_${ts}.txt"
$lines      = [System.Collections.Generic.List[string]]::new()
$lines.Add("=== Unattended Run Results — $suite — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===")
$lines.Add('')
foreach ($vmr in $vmResults) {
    $lines.Add("VM: $($vmr.VM)  Status: $($vmr.Status)")
    if ($vmr.Error)  { $lines.Add("  Error: $($vmr.Error)") }
    if ($vmr.TcMatrix) {
        $lines.Add('  TC          Fail      Ref')
        $lines.Add('  --          ----      ---')
        foreach ($row in $vmr.TcMatrix) {
            $lines.Add("  $($row.tc.PadRight(12))$($row.fail.PadRight(10))$($row.ref)")
        }
    }
    $lines.Add('')
}
$lines -join "`n" | Set-Content -LiteralPath $matrixPath -Encoding utf8
Write-Host "Matrix:       $matrixPath" -ForegroundColor Cyan

Write-Host "`n=== Run-Unattended finished at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" -ForegroundColor Cyan
