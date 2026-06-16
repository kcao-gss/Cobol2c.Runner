# TaRecovery.psm1
# Wedged-VM detection and recovery - ported from run-ta-tests/SKILL.md Step 5.5.
# Imported by Invoke-TaRun.ps1; unit-tested in tests/pester/TaRecovery.Tests.ps1.

# -- Private seams (mockable via InModuleScope in Pester) ----------------------

# cmd.exe wrapper for recovery commands (schtasks /end, shutdown /r, rdpsign).
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

# Cert-store lookup - mocked in tests so they don't require a real cert installation.
function script:Get-RdpSigningCert {
    Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq 'CN=TGFTA-RDP-Signing' } |
        Select-Object -First 1
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

function Connect-TA01Rdp {
    <#
    .SYNOPSIS
    Establishes an RDP session to the VM as TA01, restoring the interactive desktop for GUI automation.
    Uses cmdkey to store credentials silently, writes a prompt-suppressed .rdp file, optionally signs
    it with the CN=TGFTA-RDP-Signing cert (created by Setup-RdpSigning.ps1 on the controller) to
    suppress the publisher prompt, then launches mstsc.

    The signing cert is optional - if absent the .rdp is still launched. Run Setup-RdpSigning.ps1
    once on the controller to provision the cert for fully unattended operation.

    Called by Invoke-VMRecovery after the VM reboots.
    #>
    param([string]$Machine, [string]$Pass)
    $qual = "$Machine\TA01"

    # Store credential so mstsc does not prompt
    Invoke-RecoveryCmd "cmdkey /generic:TERMSRV/$Machine /user:$qual /pass:$Pass" | Out-Null

    # Locate the RDP-signing cert (optional - suppresses publisher prompt)
    $cert  = Get-RdpSigningCert
    $thumb = if ($cert) { $cert.Thumbprint } else { $null }

    # Write a minimal prompt-suppressed .rdp file (fields from SKILL.md Step 5.5)
    $dir = Join-Path $env:TEMP 'TGFTA_RDP'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $rdp = Join-Path $dir "$Machine.rdp"
    @(
        "full address:s:$Machine",
        "username:s:$qual",
        'screen mode id:i:1',
        'desktopwidth:i:1280',
        'desktopheight:i:1024',
        'redirectclipboard:i:0',
        'prompt for credentials:i:0',
        'promptcredentialonce:i:0',
        'enablecredsspsupport:i:1',
        'authentication level:i:0'
    ) | Set-Content -LiteralPath $rdp -Encoding Ascii

    # Sign to suppress the "publisher unknown" dialog (skipped when cert is absent)
    if ($thumb) { Invoke-RecoveryCmd "rdpsign.exe /sha256 $thumb `"$rdp`"" | Out-Null }

    Start-Process mstsc -ArgumentList "`"$rdp`""
}

function Invoke-VmReboot {
    <#
    .SYNOPSIS
    Reboots a VM and waits for it to come back online, then re-logs in TA01 to restore the interactive
    desktop. Used both for pre-batch fresh-boot setup (Invoke-TaRun.ps1) and inside Invoke-VMRecovery
    for wedge recovery. Keeping the logic in one place prevents drift between the two callers.
    #>
    param([string]$Machine, [string]$Ta01Pw)

    # 1) Reboot the VM (force, no grace period)
    Invoke-RecoveryCmd "shutdown /r /m \\$Machine /t 0 /f" | Out-Null

    # 2) Wait for the VM to come back: let it go down, then poll the Apps share (8-min deadline)
    Invoke-RecoverySleep -Seconds 45   # let reboot begin before probing
    $deadline = (Get-Date).AddMinutes(8)
    do { Invoke-RecoverySleep -Seconds 15 } until ((Test-VmSharePath "\\$Machine\Apps") -or (Get-Date) -gt $deadline)
    Invoke-RecoverySleep -Seconds 45   # let the auto-logon and desktop settle

    # 3) Re-login TA01 to restore the interactive desktop (GUI automation requires it)
    Connect-TA01Rdp -Machine $Machine -Pass $Ta01Pw
    Invoke-RecoverySleep -Seconds 20   # allow mstsc to fully establish the session
}

function Invoke-VMRecovery {
    <#
    .SYNOPSIS
    Recovers a wedged VM: ends the stale scheduled task, reboots the VM, waits for the share to return,
    then re-logs in TA01 to restore the interactive desktop. Ported from SKILL.md Step 5.5.

    Called by Invoke-TaRun.ps1 when Trigger A (RDP-drop signature) or Trigger B (45-min idle) fires
    and -AutoRecover is 'true'. Capped at 2 recoveries per suite run by the caller.
    #>
    param([string]$Machine, [string]$Ta01Pw, [string]$TaskName)
    $winUser = "$Machine\TA01"

    # 1) Stop the wedged run (defensive - Remove-RemoteTask already deleted the task, but /end is safe as a no-op)
    Invoke-RecoveryCmd "schtasks /end /s `"$Machine`" /u `"$winUser`" /p `"$Ta01Pw`" /tn `"$TaskName`"" | Out-Null

    # 2-4) Reboot, wait for the share to return, and re-login TA01
    Invoke-VmReboot -Machine $Machine -Ta01Pw $Ta01Pw
}

Export-ModuleMember -Function Test-RdpDropSignature, Get-AffectedTests, Connect-TA01Rdp, Invoke-VmReboot, Invoke-VMRecovery
