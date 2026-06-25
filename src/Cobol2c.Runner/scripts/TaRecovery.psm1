# TaRecovery.psm1
# Wedged-VM detection and recovery - ported from run-ta-tests/SKILL.md Step 5.5.
# Imported by Invoke-TaRun.ps1; unit-tested in tests/pester/TaRecovery.Tests.ps1.

# -- Private seams (mockable via InModuleScope in Pester) ----------------------

# cmd.exe wrapper for recovery commands (schtasks /end, shutdown /r).
function script:Invoke-RecoveryCmd {
    param([string]$Command)
    $output = & cmd /c $Command 2>&1
    return [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
}

# Sleep wrapper - mocked in tests to avoid real waits.
function script:Invoke-RecoverySleep {
    param([int]$Seconds)
    Start-Sleep -Seconds $Seconds
}

# UNC share probe - mocked in tests so they don't block on a real network path.
function script:Test-VmSharePath {
    param([string]$Path)
    Test-Path -LiteralPath $Path
}

# -- Detection functions --------------------------------------------------------

function Test-RdpDropSignature {
    <#
    .SYNOPSIS
    Returns $true when 3+ consecutive trailing failures in $LogDir carry the RDP-drop signature:
    "Cannot maximize window" AND the scrollParent/textblock "No matching UI object" timeout message.
    Trigger A - the interactive desktop stopped rendering (RDP session dropped or minimized).
    Pass detection mirrors Get-TcResults: Passed:&nbsp;[1-9] = pass; anything else = fail.
    #>
    param([string]$LogDir)

    $htmls = @(Get-ChildItem -LiteralPath $LogDir -Filter '*.html' -File -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime)
    if ($htmls.Count -lt 3) { return $false }

    # Walk backwards (newest first) to collect the trailing run of consecutive failures
    $trailingFails = [System.Collections.Generic.List[object]]::new()
    foreach ($h in ($htmls | Sort-Object LastWriteTime -Descending)) {
        if (Select-String -LiteralPath $h.FullName -Pattern 'Passed:&nbsp;[1-9]' -Quiet) { break }
        $trailingFails.Add($h)
    }
    if ($trailingFails.Count -lt 3) { return $false }

    # Check whether any of the 3 most-recent trailing fails carry both signature markers
    foreach ($h in ($trailingFails | Select-Object -First 3)) {
        $raw = Get-Content -LiteralPath $h.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $raw) { continue }
        # Strip tags, HtmlDecode, collapse whitespace - mirrors the skill's diagnostic approach
        $text = ([System.Net.WebUtility]::HtmlDecode(($raw -replace '<[^>]+>', ' '))) -replace '\s+', ' '
        if (($text -match 'Cannot maximize window') -and
            ($text -match 'No matching UI object found for.*ta class\s*=\s*textblock.*automation id\s*=\s*scrollParent.*timeout of "20" seconds')) {
            return $true
        }
    }
    return $false
}

function Get-AffectedTests {
    <#
    .SYNOPSIS
    Returns the subset of $AllTests that need to be re-run after a VM recovery.
    Trigger A: TCs whose result HTML contains the RDP-drop signature.
    Trigger B: The hung TC (last-executing TC from StartedTail) plus any TC with no result HTML yet.
    #>
    param(
        [string] $Trigger,
        [string] $LogDir,
        [string] $StartedTail,   # last line of started.txt at time of detection
        [array]  $AllTests
    )

    if ($Trigger -eq 'A') {
        $htmls    = Get-ChildItem -LiteralPath $LogDir -Filter '*.html' -File -ErrorAction SilentlyContinue
        $affected = [System.Collections.Generic.List[string]]::new()
        foreach ($h in $htmls) {
            $raw = Get-Content -LiteralPath $h.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $raw) { continue }
            $text = ([System.Net.WebUtility]::HtmlDecode(($raw -replace '<[^>]+>', ' '))) -replace '\s+', ' '
            if (($text -match 'Cannot maximize window') -and
                ($text -match 'No matching UI object found for.*ta class\s*=\s*textblock.*automation id\s*=\s*scrollParent.*timeout of "20" seconds')) {
                if ($h.Name -match '^(\d+)\b') { $affected.Add($matches[1]) }
            }
        }
        return @($AllTests | Where-Object { $_.tc -in $affected })
    }

    if ($Trigger -eq 'B') {
        # Hung TC: extract from started.txt last line, e.g. "[...] Running TC 27510 [Inventory/...]"
        $hungTc = $null
        if ($StartedTail -match '\bTC\s+(\d+)\b') { $hungTc = $matches[1] }

        # TCs with no result HTML yet
        $existingTcs = @(Get-ChildItem -LiteralPath $LogDir -Filter '*.html' -File -ErrorAction SilentlyContinue |
                         ForEach-Object { if ($_.Name -match '^(\d+)\b') { $matches[1] } })

        return @($AllTests | Where-Object { $_.tc -eq $hungTc -or $_.tc -notin $existingTcs })
    }

    return $AllTests   # fallback: re-run everything
}

# -- Recovery actuators ---------------------------------------------------------

function Invoke-VmReboot {
    <#
    .SYNOPSIS
    Reboots a VM and waits for it to come back online, then lets auto-logon settle the desktop.
    Used both for pre-batch fresh-boot setup (Invoke-TaRun.ps1) and inside Invoke-VMRecovery
    for wedge recovery. Keeping the logic in one place prevents drift between the two callers.

    VMs use console auto-logon: after a reboot, Windows boots straight into an unlocked TA01
    desktop (Session 1) without any RDP connection required.
    #>
    param([string]$Machine, [string]$Ta01Pw)

    # 1) Reboot the VM (force, no grace period)
    Invoke-RecoveryCmd "shutdown /r /m \\$Machine /t 0 /f" | Out-Null

    # 2) Wait for the VM to come back: let it go down, then poll the Apps share (8-min deadline)
    Invoke-RecoverySleep -Seconds 45   # let reboot begin before probing
    $deadline = (Get-Date).AddMinutes(8)
    do { Invoke-RecoverySleep -Seconds 15 } until ((Test-VmSharePath "\\$Machine\Apps") -or (Get-Date) -gt $deadline)

    # 3) Let auto-logon and the desktop settle (console auto-logon re-establishes unlocked Session 1)
    Invoke-RecoverySleep -Seconds 45
}

function Invoke-VMRecovery {
    <#
    .SYNOPSIS
    Recovers a wedged VM: ends the stale scheduled task, reboots the VM, waits for the share to
    return, then lets auto-logon re-establish the desktop. Ported from SKILL.md Step 5.5.

    Called by Invoke-TaRun.ps1 when Trigger A (RDP-drop signature) or Trigger B (45-min idle) fires
    and -AutoRecover is 'true'. Capped at 2 recoveries per suite run by the caller.
    #>
    param([string]$Machine, [string]$Ta01Pw, [string]$TaskName)
    $winUser = "$Machine\TA01"

    # 1) Stop the wedged run (defensive - Remove-RemoteTask already deleted the task, but /end is safe as a no-op)
    Invoke-RecoveryCmd "schtasks /end /s `"$Machine`" /u `"$winUser`" /p `"$Ta01Pw`" /tn `"$TaskName`"" | Out-Null

    # 2-3) Reboot and wait for auto-logon to settle
    Invoke-VmReboot -Machine $Machine -Ta01Pw $Ta01Pw
}

Export-ModuleMember -Function Test-RdpDropSignature, Get-AffectedTests, Invoke-VmReboot, Invoke-VMRecovery
