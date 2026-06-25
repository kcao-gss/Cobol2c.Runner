# TaRecovery.psm1
# Wedged-VM detection and recovery — ported from run-ta-tests/SKILL.md Step 5.5.
# Imported by Invoke-TaRun.ps1; unit-tested in tests/pester/TaRecovery.Tests.ps1.

# ── Private seams (mockable via InModuleScope in Pester) ──────────────────────

# cmd.exe wrapper for recovery commands (schtasks /end, shutdown /r, rdpsign).
function script:Invoke-RecoveryCmd {
    param([string]$Command)
    $output = & cmd /c $Command 2>&1
    return [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
}

# Sleep wrapper — mocked in tests to avoid real waits.
function script:Invoke-RecoverySleep {
    param([int]$Seconds)
    Start-Sleep -Seconds $Seconds
}

# UNC share probe — mocked in tests so they don't block on a real network path.
function script:Test-VmSharePath {
    param([string]$Path)
    Test-Path -LiteralPath $Path
}

# Cert-store lookup — mocked in tests so they don't require a real cert installation.
function script:Get-RdpSigningCert {
    Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq 'CN=TGFTA-RDP-Signing' } |
        Select-Object -First 1
}

# File-read seam for park.log — mocked in tests.
function script:Read-ParkLog {
    param([string]$Path)
    Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
}

# ── Detection functions ────────────────────────────────────────────────────────

function Test-RdpDropSignature {
    <#
    .SYNOPSIS
    Returns $true when 3+ consecutive trailing failures in $LogDir carry the RDP-drop signature:
    "Cannot maximize window" AND the scrollParent/textblock "No matching UI object" timeout message.
    Trigger A — the interactive desktop stopped rendering (RDP session dropped or minimized).
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
        # Strip tags, HtmlDecode, collapse whitespace — mirrors the skill's diagnostic approach
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

# ── Recovery actuators ─────────────────────────────────────────────────────────

function Connect-TA01Rdp {
    <#
    .SYNOPSIS
    Establishes an RDP session to the VM as TA01, restoring the interactive desktop for GUI automation.
    Uses cmdkey to store credentials silently, writes a prompt-suppressed .rdp file, optionally signs
    it with the CN=TGFTA-RDP-Signing cert (created by Setup-RdpSigning.ps1 on the controller) to
    suppress the publisher prompt, then launches mstsc.

    The signing cert is optional — if absent the .rdp is still launched. Run Setup-RdpSigning.ps1
    once on the controller to provision the cert for fully unattended operation.

    Called by Invoke-VMRecovery after the VM reboots (attended mode). In headless mode,
    Enter-ConsoleSession is used instead.
    #>
    param([string]$Machine, [string]$Pass)
    $qual = "$Machine\TA01"

    # Store credential so mstsc does not prompt
    Invoke-RecoveryCmd "cmdkey /generic:TERMSRV/$Machine /user:$qual /pass:$Pass" | Out-Null

    # Locate the RDP-signing cert (optional — suppresses publisher prompt)
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

function Enter-ConsoleSession {
    <#
    .SYNOPSIS
    Headless session bootstrap — parks TA01's session onto the physical console so GUI
    automation renders with zero RDP viewer.

    Steps:
      1. Deploy console-park.ps1 to the VM via C$ (\\<Machine>\C$\Windows\Temp\).
      2. Create and run a SYSTEM scheduled task on the VM that executes it.
      3. Wait briefly, then read back park.log to confirm tscon succeeded.
      4. Delete the task. Return $true on success, $false on any failure.

    Idempotent — safe to call on an already-parked session (tscon with a console session
    already active is a benign no-op on most Windows builds).
    #>
    param([string]$Machine, [string]$Ta01Pw)

    $winUser      = "$Machine\TA01"
    $parkTaskName = 'Cobol2c_ConsolePark'
    $scriptDir    = $PSScriptRoot
    $localPark    = Join-Path $scriptDir 'console-park.ps1'

    # Resolve hostname to IPv4 to avoid SMB using a link-local IPv6 address (error 67).
    $smbHost = $Machine
    try {
        $ipv4 = [System.Net.Dns]::GetHostAddresses($Machine) |
                Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
                Select-Object -ExpandProperty IPAddressToString -First 1
        if ($ipv4) { $smbHost = $ipv4 }
    } catch { }

    # ── 1) Deploy console-park.ps1 via Apps share (C$ may not be available on non-domain VMs) ──
    $appsShare = "\\$smbHost\Apps"
    $rApps = Invoke-RecoveryCmd ("net use `"$appsShare`" /user:`"$winUser`" `"$Ta01Pw`"")
    if ($rApps.ExitCode -ne 0) {
        Write-Warning ("Enter-ConsoleSession: net use Apps failed on $Machine (exit " + $rApps.ExitCode + "): " + (($rApps.Output) -join ' '))
        return $false
    }

    try {
        $dest = "\\$smbHost\Apps\TA-CMD\console-park.ps1"
        Copy-Item -LiteralPath $localPark -Destination $dest -Force -ErrorAction Stop
    } catch {
        $errMsg = $_
        Write-Warning ("Enter-ConsoleSession: failed to copy console-park.ps1 to " + $Machine + " Apps share: " + $errMsg)
        Invoke-RecoveryCmd "net use `"$appsShare`" /delete" | Out-Null
        return $false
    }

    # ── 2) Run as SYSTEM via schtasks ───────────────────────────────────────
    # Script path on VM: C:\Apps\TA-CMD\console-park.ps1 (Apps share -> C:\Apps)
    $parkCmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Apps\TA-CMD\console-park.ps1'
    Invoke-RecoveryCmd ("schtasks /delete /s `"$Machine`" /u `"$winUser`" /p `"$Ta01Pw`"" +
                         " /tn `"$parkTaskName`" /f") | Out-Null   # remove stale task, ignore errors

    $create = Invoke-RecoveryCmd ("schtasks /create /s `"$Machine`" /u `"$winUser`" /p `"$Ta01Pw`"" +
                                   " /tn `"$parkTaskName`" /tr `"$parkCmd`"" +
                                   " /sc ONCE /st 23:59 /ru SYSTEM /rl HIGHEST /f")
    if ($create.ExitCode -ne 0) {
        Write-Warning ("Enter-ConsoleSession: schtasks /create failed on $Machine (exit " + $create.ExitCode + "): " + (($create.Output) -join ' '))
        Invoke-RecoveryCmd "net use `"$appsShare`" /delete" | Out-Null
        return $false
    }

    $run = Invoke-RecoveryCmd "schtasks /run /s `"$Machine`" /u `"$winUser`" /p `"$Ta01Pw`" /tn `"$parkTaskName`""
    if ($run.ExitCode -ne 0) {
        Write-Warning ("Enter-ConsoleSession: schtasks /run failed on $Machine (exit " + $run.ExitCode + "): " + (($run.Output) -join ' '))
        Invoke-RecoveryCmd "net use `"$appsShare`" /delete" | Out-Null
        return $false
    }

    # ── 3) Wait for console-park.ps1 to complete, then read park.log ────────
    Invoke-RecoverySleep -Seconds 15

    # Read park.log from Apps share (written by updated console-park.ps1 to C:\Apps\TA-CMD\park.log)
    $logPath  = "\\$smbHost\Apps\TA-CMD\park.log"
    $parkLog  = Read-ParkLog -Path $logPath
    $succeeded = $false

    if ($parkLog) {
        # park.log mixes UTF-8 header lines with UTF-16LE qwinsta output (embedded null bytes).
        # Strip null bytes so regex patterns work regardless of encoding artifact.
        $parkLogNorm = $parkLog -replace '\x00', ''

        # tscon exit=0 = session moved to console.
        # tscon exit=1 = session already IS the console (Active) — also success.
        if ($parkLogNorm -match 'exit=0' -or
            $parkLogNorm -match '(?i)console\s+\d+\s+Active' -or
            ($parkLogNorm -match 'exit=1' -and $parkLogNorm -match '(?i)TA01')) {
            $succeeded = $true
        }
        Write-Verbose ("Enter-ConsoleSession: park.log from " + $Machine + ":`n" + $parkLogNorm)
    } else {
        Write-Warning ("Enter-ConsoleSession: park.log not readable from " + $Machine + " - tscon may have failed.")
    }

    # ── 4) Clean up the scheduled task ─────────────────────────────────────
    Invoke-RecoveryCmd ("schtasks /delete /s `"$Machine`" /u `"$winUser`" /p `"$Ta01Pw`"" +
                         " /tn `"$parkTaskName`" /f") | Out-Null
    Invoke-RecoveryCmd "net use `"$appsShare`" /delete" | Out-Null

    if (-not $succeeded) {
        Write-Warning ("Enter-ConsoleSession: console park did not confirm exit=0 on $Machine. Check park.log.")
    }
    return $succeeded
}

function Invoke-VMRecovery {
    <#
    .SYNOPSIS
    Recovers a wedged VM: ends the stale scheduled task, reboots the VM, waits for the share to return,
    then restores the interactive desktop. In headless mode, uses Enter-ConsoleSession (console park)
    instead of Connect-TA01Rdp (mstsc). Ported from SKILL.md Step 5.5.

    Called by Invoke-TaRun.ps1 when Trigger A (RDP-drop signature) or Trigger B (45-min idle) fires
    and -AutoRecover is 'true'. Capped at 2 recoveries per suite run by the caller.
    #>
    param([string]$Machine, [string]$Ta01Pw, [string]$TaskName, [switch]$Headless)
    $winUser = "$Machine\TA01"

    # 1) Stop the wedged run (defensive — Remove-RemoteTask already deleted the task, but /end is safe as a no-op)
    Invoke-RecoveryCmd "schtasks /end /s `"$Machine`" /u `"$winUser`" /p `"$Ta01Pw`" /tn `"$TaskName`"" | Out-Null

    # 2) Reboot the VM (force, no grace period)
    Invoke-RecoveryCmd "shutdown /r /m \\$Machine /t 0 /f" | Out-Null

    # 3) Wait for the VM to come back: let it go down, then poll the Apps share (8-min deadline)
    Invoke-RecoverySleep -Seconds 45   # let reboot begin before probing
    $deadline = (Get-Date).AddMinutes(8)
    do { Invoke-RecoverySleep -Seconds 15 } until ((Test-VmSharePath "\\$Machine\Apps") -or (Get-Date) -gt $deadline)
    Invoke-RecoverySleep -Seconds 45   # let the auto-logon and desktop settle

    # 4) Restore the interactive desktop
    if ($Headless) {
        # Headless: park TA01's session onto the console (no mstsc needed)
        Enter-ConsoleSession -Machine $Machine -Ta01Pw $Ta01Pw | Out-Null
        Invoke-RecoverySleep -Seconds 10   # allow console session to settle
    } else {
        # Attended: open an RDP viewer on the controller to render the desktop
        Connect-TA01Rdp -Machine $Machine -Pass $Ta01Pw
        Invoke-RecoverySleep -Seconds 20   # allow mstsc to fully establish the session
    }
}

Export-ModuleMember -Function Test-RdpDropSignature, Get-AffectedTests, Connect-TA01Rdp, `
                               Enter-ConsoleSession, Invoke-VMRecovery
