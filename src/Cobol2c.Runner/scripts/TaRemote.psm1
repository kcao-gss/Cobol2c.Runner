# TaRemote.psm1
# Remote-push primitives for Cobol2c.Runner — ported from run-ta-tests/SKILL.md Steps 3-6.
# All credentials are parameters; none are hardcoded in this module.
# Imported by Invoke-TaRun.ps1; unit-tested in tests/pester/TaRemote.Tests.ps1.

# Script-level cmd.exe wrapper — mockable in Pester tests via InModuleScope / -ModuleName.
# stdin is always redirected from NUL so net use / schtasks / cmdkey never block on an
# interactive prompt (credential dialog, "overwrite? [Y/N]", etc.) regardless of how the
# calling pwsh process was launched.  A per-call timeout (default 30 s) surfaces hangs as
# a thrown error instead of blocking the pipeline indefinitely.
function script:Invoke-Cmd {
    param(
        [string]$Command,
        [int]$TimeoutSeconds = 30
    )
    $job = Start-Job -ScriptBlock {
        param($cmd)
        # "< NUL" closes the child process's stdin — belt-and-suspenders on top of the job
        # isolation.  The job itself already has no interactive stdin, but explicit NUL
        # redirect ensures cmd /c and every grandchild it spawns also get a closed stdin.
        $output = & cmd /c "$cmd < NUL" 2>&1
        [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
    } -ArgumentList $Command

    if (-not (Wait-Job $job -Timeout $TimeoutSeconds)) {
        Stop-Job    $job
        Remove-Job  $job
        throw "Invoke-Cmd timed out after ${TimeoutSeconds}s: $Command"
    }
    $result = Receive-Job $job
    Remove-Job $job
    return $result
}

function Assert-VmReady {
    <#
    .SYNOPSIS
    Preflight probe: verify the VM is up, the Apps share exists, and the remote schtasks RPC
    channel is open. Throws with a specific, actionable message on the first failing layer so
    "VM powered off" and "share not provisioned" are never misread as EDR blocking.

    Layers (matches the diagnostic proven against TGFTA-118 on 2026-06-15):
      L2 — TCP 445 / 135 (network: VM up vs. off/network-blocked)
      L3 — net use \\<vm>\Apps (SMB session: share exists vs. missing, or auth failure)
      L4 — schtasks /query /s (RPC: firewall rule open vs. missing or port filtered)
    #>
    param([string]$Machine, [string]$Ta01Pw)

    $winUser = "$Machine\TA01"

    # L2: TCP 445 (SMB) and 135 (RPC endpoint mapper)
    $tcp445 = Test-NetConnection -ComputerName $Machine -Port 445 -WarningAction SilentlyContinue
    $tcp135 = Test-NetConnection -ComputerName $Machine -Port 135 -WarningAction SilentlyContinue

    if (-not $tcp445.TcpTestSucceeded) {
        throw ("VM DOWN or NETWORK BLOCK: TCP 445 refused/timeout on $Machine. " +
               "VM pool reboots daily ~6:30 PM — bring the VM up and retry. " +
               "(TCP 135 state: $($tcp135.TcpTestSucceeded))")
    }
    if (-not $tcp135.TcpTestSucceeded) {
        throw ("TCP 135 (RPC endpoint mapper) refused on $Machine although TCP 445 is open. " +
               "The 'Remote Scheduled Tasks Management' firewall rule is not enabled. " +
               "Run Setup-Vm.ps1 on the VM as admin.")
    }

    # L3: net use — tests auth + share existence
    $r = Invoke-Cmd "net use `"\\$Machine\Apps`" /user:`"$winUser`" `"$Ta01Pw`""
    if ($r.ExitCode -ne 0) {
        # Disconnect any partial session before throwing
        Invoke-Cmd "net use `"\\$Machine\Apps`" /delete" | Out-Null
        $err = (($r.Output) -join ' ').Trim()
        if ($err -match '(?i)error 67|bad network name') {
            throw ("SHARE MISSING: Apps share not found on $Machine (net use error 67 = bad network name). " +
                   "Run Setup-Vm.ps1 on the VM to create the Apps share and the TA-CMD subfolder. " +
                   "Note: VMs lose manual share setup after daily reboot/reassignment. Raw: $err")
        }
        if ($err -match '(?i)error 5\b|error 1326|access is denied|logon failure') {
            throw ("AUTH FAILURE: Access denied connecting to \\$Machine\Apps (error 5 or 1326). " +
                   "Verify the TA01 account password. Raw: $err")
        }
        throw ("NET USE FAILED (\\$Machine\Apps, exit $($r.ExitCode)): $err")
    }
    # Probe succeeded — disconnect immediately, this was only a test
    Invoke-Cmd "net use `"\\$Machine\Apps`" /delete" | Out-Null

    # L4: schtasks /query — same RPC channel as /create, but read-only
    $sq = Invoke-Cmd "schtasks /query /s `"$Machine`" /u `"$winUser`" /p `"$Ta01Pw`""
    if ($sq.ExitCode -ne 0) {
        $err = (($sq.Output) -join ' ').Trim()
        if ($err -match '(?i)rpc server') {
            throw ("REMOTE TASK SCHEDULER UNREACHABLE on $Machine (RPC server unavailable). " +
                   "TCP 445 and 135 are open but schtasks /query /s failed. " +
                   "Enable the 'Remote Scheduled Tasks Management' firewall rule via Setup-Vm.ps1. " +
                   "Raw: $err")
        }
        throw ("SCHTASKS /QUERY FAILED ($Machine, exit $($sq.ExitCode)): $err")
    }
}

function Connect-VmShare {
    <#
    .SYNOPSIS
    Establish an authenticated SMB session to \\$Machine\Apps using TA01 credentials.
    Must be called before Copy-BatToVm and Invoke-RemoteTask; cleaned up by Remove-RemoteTask.
    #>
    param([string]$Machine, [string]$Ta01Pw)
    $r = Invoke-Cmd "net use `"\\$Machine\Apps`" /user:`"$Machine\TA01`" `"$Ta01Pw`""
    if ($r.ExitCode -ne 0) {
        throw ("Connect-VmShare: net use failed ($Machine, exit $($r.ExitCode)): " +
               (($r.Output) -join ' '))
    }
}

function Disconnect-VmShare {
    <#
    .SYNOPSIS
    Release the SMB session to \\$Machine\Apps. Idempotent — safe when no session exists.
    #>
    param([string]$Machine)
    Invoke-Cmd "net use `"\\$Machine\Apps`" /delete" | Out-Null
}

function Copy-BatToVm {
    <#
    .SYNOPSIS
    Copy a batch file from the controller to \\$Machine\Apps\TA-CMD.
    Requires a prior Connect-VmShare call to have established the SMB session.
    #>
    param([string]$Machine, [string]$BatPath)
    Copy-Item -Path $BatPath -Destination "\\$Machine\Apps\TA-CMD" -Force -ErrorAction Stop
}

function Invoke-RemoteTask {
    <#
    .SYNOPSIS
    Create and immediately trigger a one-shot interactive scheduled task on the remote VM.
    The task runs as TA01 in TA01's active desktop session — required for GUI automation.

    Critical schtasks flags — do NOT alter without testing end-to-end on a live VM:
      /ru TA01    — BARE local username (machine-qualified "TGFTA-118\TA01" fails SID lookup for /ru)
      /it         — interactive: binds the task to the TA01 logged-on session (without this,
                    TA GUI may launch in Session 0 with no display, causing silent hangs)
      NO /rp      — INTENTIONALLY omitted: /rp forces Session 0, breaking GUI automation entirely
      /rl HIGHEST — required so the batch can stop GssSystemIntegrityService
      /f          — force-recreate if the task name already exists (idempotent on retry)
      /u /p       — remote connection credentials; machine-qualified IS correct here (connection auth)
    #>
    param([string]$Machine, [string]$Ta01Pw, [string]$TaskName, [string]$BatPath)

    $winUser = "$Machine\TA01"

    $create = Invoke-Cmd ("schtasks /create /s `"$Machine`" /u `"$winUser`" /p `"$Ta01Pw`"" +
                           " /tn `"$TaskName`" /tr `"`"$BatPath`"`"" +
                           " /sc ONCE /st 23:59 /ru TA01 /it /rl HIGHEST /f")
    if ($create.ExitCode -ne 0) {
        throw ("Invoke-RemoteTask: schtasks /create failed ($Machine / $TaskName, exit $($create.ExitCode)): " +
               (($create.Output) -join ' '))
    }

    # Trigger immediately — /st 23:59 is irrelevant; /run fires regardless of the scheduled time
    $run = Invoke-Cmd "schtasks /run /s `"$Machine`" /u `"$winUser`" /p `"$Ta01Pw`" /tn `"$TaskName`""
    if ($run.ExitCode -ne 0) {
        throw ("Invoke-RemoteTask: schtasks /run failed ($Machine / $TaskName, exit $($run.ExitCode)): " +
               (($run.Output) -join ' '))
    }
}

function Remove-RemoteTask {
    <#
    .SYNOPSIS
    Delete the scheduled task from the remote VM and disconnect the Apps SMB session.
    Idempotent — always call in a finally block; safe even if the task was never created.
    #>
    param([string]$Machine, [string]$Ta01Pw, [string]$TaskName)
    $winUser = "$Machine\TA01"
    Invoke-Cmd ("schtasks /delete /s `"$Machine`" /u `"$winUser`" /p `"$Ta01Pw`"" +
                " /tn `"$TaskName`" /f") | Out-Null
    Disconnect-VmShare -Machine $Machine
}

Export-ModuleMember -Function Assert-VmReady, Connect-VmShare, Disconnect-VmShare, `
                               Copy-BatToVm, Invoke-RemoteTask, Remove-RemoteTask
