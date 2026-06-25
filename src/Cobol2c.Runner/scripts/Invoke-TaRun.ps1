<#
.SYNOPSIS
Remote-push TA execution controller — pushes test execution to a remote VM via schtasks /s + SMB,
polls completion via TAShare marker files, then emits a TaRunResult JSON to stdout.

Runs both the failing suite (e.g. Cobol2C) AND the SP2V6 reference suite on the target VM.
Results (HTML, CoreLogs, markers) are written by the remote batch to TAShare\<Suite>\Logs\<Machine>,
readable by both the VM and this controller through the same UNC path.

No local process execution. The runner runs on a central controller host; TA runs on the VM.

Requires:
  - VPN / GSS network access to \\gss2k19rnd.gss.local (TAShare reads AND Logs writes)
  - TA01 logged in on the target VM with desktop UNLOCKED (GUI automation requires interactive session)
  - One-time per-VM admin setup (run Setup-Vm.ps1 on each VM):
      LocalAccountTokenFilterPolicy=1, Remote Scheduled Tasks firewall rule, Apps share + TA-CMD folder
  - \\gss2k19rnd.gss.local\TAShare\<Suite>\tc-manifest.json  (TC -> rep/prj/treepath)
  - VMs must be configured with console auto-logon for TA01 so reboot recovery is fully headless
      (no RDP re-login required; Windows boots straight into an unlocked TA01 desktop).

TC manifest format (one-time setup, populate using ta_generate_execute_bat MCP tool):
  [ { "tc":"27510", "rep":"Inventory", "prj":"Inventory",
      "path":"/Production/2023 version/Inventory/Inventory Parts/27510_Inv_Add Cross Reference records {new program}" } ]

.PARAMETER Suite       Failing suite: "Cobol2C" | "SP2V6" | "Production"
.PARAMETER Machine     VM name, e.g. "TGFTA-118"
.PARAMETER Tcs         Comma-separated TC numbers, e.g. "27510,27511"
.PARAMETER Logging     "true" | "false"  (enables AutoTrace CoreLog capture; required for triage)
.PARAMETER Ta01Pw      Password for the TA01 local account on the VM (REQUIRED)
.PARAMETER ClearLogs   "true" (default) clears the TAShare log folder before the run
.PARAMETER AutoRecover "true" (default). On a VM wedge (Trigger A: RDP-drop signature; Trigger B:
                        started.txt idle 45+ min), automatically reboots the VM, re-logs in TA01,
                        and re-runs only the affected TCs - capped at 2 recoveries per suite.
                        "false" preserves the old behavior: throws an actionable error on wedge.
#>
param(
    [string]$Suite,
    [string]$Machine,
    [string]$Tcs,
    [string]$Logging          = 'true',
    [string]$Ta01Pw,
    [string]$ClearLogs        = 'true',
    [string]$AutoRecover      = 'true',
    [string]$RebootBeforeRun  = 'true'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# -- Validate required credential -----------------------------------------------
if ([string]::IsNullOrWhiteSpace($Ta01Pw)) {
    throw ('Ta01Pw is required for remote-push execution. ' +
           'Set the Runner__Ta01Pw environment variable (the TA01 local account password).')
}

# -- Parse inputs ---------------------------------------------------------------
$tcNums      = @($Tcs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$isLogging   = $Logging     -eq 'true'
$doClear     = $ClearLogs   -ne 'false'
$autoRecover      = $AutoRecover
$rebootBeforeRun  = $RebootBeforeRun -eq 'true'
$RefSuite         = 'SP2V6'    # reference baseline: SP2V6 uses the original COBOL programs
$scriptDir   = $PSScriptRoot

# -- Import modules -------------------------------------------------------------
Import-Module (Join-Path $scriptDir 'TaRemote.psm1')   -Force
Import-Module (Join-Path $scriptDir 'TaRecovery.psm1') -Force

# -- TAShare paths --------------------------------------------------------------
# FQDN is required - the NetBIOS short name silently breaks marker writes on non-domain VMs.
$FailBase    = "\\gss2k19rnd.gss.local\TAShare\$Suite"
$RefBase     = "\\gss2k19rnd.gss.local\TAShare\$RefSuite"

# Results are written by the remote batch to TAShare\Logs; the controller reads them via the same UNC.
$FailLogDir  = "\\gss2k19rnd.gss.local\TAShare\$Suite\Logs\$Machine"
$RefLogDir   = "\\gss2k19rnd.gss.local\TAShare\$RefSuite\Logs\$Machine"

# -- Batch generator (ported from run-ta-tests/SKILL.md Step 2) -----------------
# $HtmlDir is a UNC path on TAShare - written by the VM batch, read by the controller for polling.
function New-TABatch ([string]$Base, [array]$Tests, [bool]$IsLogging, [string]$HtmlDir, [string]$RunToken, [string]$SuiteName, [string]$Ta01Pw) {
    $kw      = if ($IsLogging) { 'new program,batch,2023,log,without service' }
               else             { 'new program,batch,2023,without service' }
    # c2c flips GSS Communication Options Location to "COBOL 2 C#" (IVAL=3) so the suite runs against the
    # converted programs. Cobol2C only - the SP2V6 reference must stay on the legacy baseline.
    if ($SuiteName -eq 'Cobol2C') { $kw = "$kw,c2c" }
    $html    = $HtmlDir
    $tcLabel = ($Tests | ForEach-Object { $_.tc }) -join ', '
    $esc     = { param($s) (($s -replace '\^','^^') -replace '([&<>|()])','^$1') -replace '%','%%' }
    $capArgs = ''
    $L = [System.Collections.Generic.List[string]]::new()

    $L.Add('@echo off')
    $L.Add('title TestArchitect - Command Line Tool')
    $L.Add('chcp.com 65001 >nul')
    $L.Add("REM Machine: $Machine   Logging: $IsLogging   TCs: $tcLabel")
    $L.Add('')
    $L.Add('set LS=172.16.43.66:8778')
    $L.Add('set RS=172.16.43.66:53400')
    $L.Add('set USER=GSSTester')
    $L.Add('set PASS=04848555D4C')
    $L.Add("set KEYWORDS=$kw")
    $L.Add('set STARTUP=env file path=uds=\\\\172.16.60.6\\Artifacts\\LG-Automation Data\\Env setup\\logigear env.xml')
    $L.Add('set HARNESS_FWD=C:/GSS Harness/run.bat')
    $L.Add("set HARNESS_CMD='C:\GSS Harness\run.bat'")
    $L.Add("set HTML=$html")
    $L.Add('set UDF=build number=')
    if ($IsLogging) {
        $L.Add('set CAPTURECOND=Failed')
        $L.Add('set CAPTURELIMIT=3')
        $capArgs = ' -cc "%CAPTURECOND%" -cl "%CAPTURELIMIT%"'
    }
    $L.Add('')
    $L.Add('if not exist "%HTML%" mkdir "%HTML%"')
    $L.Add('REM 1) mark start; per-TC lines appended below')
    $L.Add('echo [%DATE% %TIME%] BATCH STARTED - deploying updated programs> "%HTML%\started.txt"')
    $L.Add('REM 1b) provision credential for the 172.16.60.6 env/test-data share. VMs LOSE this on reboot;')
    $L.Add('REM      without it EVERY test exits at init with "logigear env.xml does not exist" (whole-fleet 0-pass).')
    $L.Add("cmdkey /add:172.16.60.6 /user:TGFTA-01\TA01 /pass:$Ta01Pw > `"%HTML%\cmdkey.log`" 2>&1")
    $L.Add('REM 2) stop integrity service so it cannot roll back the updated programs')
    $L.Add('echo Y| net stop "GssSystemIntegrityService" > "%HTML%\service-stop.log" 2>&1')
    $L.Add('REM 3) deploy updated programs from TAShare')
    $L.Add(('robocopy "{0}\Bin" "C:\Apps\Global\Bin" /E /R:1 /W:1 /NP > "%HTML%\copy-bin.log" 2>&1' -f $Base))
    $L.Add('REM 3b) machine-specific overrides (optional <machine>Bin folder; copied AFTER base so it wins)')
    $L.Add(('if exist "{0}\" (robocopy "{0}" "C:\Apps\Global\Bin" /E /R:1 /W:1 /NP > "%HTML%\copy-machine-bin.log" 2>&1) else (echo No machine-specific Bin: {0}> "%HTML%\copy-machine-bin.log")' -f "$Base\${Machine}Bin"))
    $L.Add('REM 4) deploy plugins')
    $L.Add(('robocopy "{0}\Plugins" "C:\Apps\Global\Plugins" /E /R:1 /W:1 /NP > "%HTML%\copy-plugins.log" 2>&1' -f $Base))
    $L.Add('REM 5) unblock mark-of-the-web on the copied programs')
    $L.Add('powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath ''C:\Apps\Global\Bin'' -Recurse -File | Unblock-File" > "%HTML%\unblock-bin.log" 2>&1')
    $L.Add('')
    foreach ($t in $Tests) {
        $leaf   = ($t.path -split '/')[-1]
        $status = & $esc ("Running TC {0} [{1}/{2}]: {3}" -f $t.tc, $t.rep, $t.prj, $leaf)
        # -r must start with "<tc>_" and must NOT contain { } < > (aborts TA CLI with 0x84104016)
        $rname  = ($leaf -replace '\s*\{[^}]*\}', '').Trim()
        # Strip the trailing {variation} from -t too. The variation is selected at RUNTIME by the comma
        # -kwd keyword set (which includes "new program"), NOT by the path. Leaving {new program} in -t
        # pins the base variation -> keyword selection never fires -> the test silently runs the OLD
        # programs (wrong build). So -t MUST be the BASE path with the trailing {variation} removed.
        $tpath  = ($t.path -replace '\s*\{[^}]*\}\s*$', '')
        $cmd    = ('ta execute -ls "%LS%" -rep "{0}" -prj "{1}" -u "%USER%" -p "%PASS%" -t "{2}" -rs "%RS%" -ss "%STARTUP%" -kwd "%KEYWORDS%" -tscript "%HARNESS_FWD%" -tcmd "%HARNESS_CMD%" -tpath "%HARNESS_FWD%" -html "%HTML%" -subfld "0" -subhtml "0" -udf "%UDF%"{4} -r "{3}" -up "/{1}/Results/ManualRuns/{{year}}_{{month}}_{{day}}"' `
                  -f $t.rep, $t.prj, $tpath, $rname, $capArgs)
        $L.Add("REM --- TC $($t.tc) ---")
        $L.Add("echo [%DATE% %TIME%] $status>> `"%HTML%\started.txt`"")
        $L.Add("$cmd > `"%HTML%\ta-exec-$($t.tc).log`" 2>&1")
        $L.Add('')
    }
    $L.Add('REM Copy CoreLog to TAShare log folder (/COPY:D preserves LastWriteTime for age check)')
    $L.Add('if exist "C:\Apps\Global\Files\AutoTrace" robocopy "C:\Apps\Global\Files\AutoTrace" "%HTML%\CoreLogs" CoreLog*.glog /R:1 /W:1 /NP /COPY:D >nul 2>&1')
    $L.Add("echo ${RunToken}>`"%HTML%\finished.txt`"")
    return ($L -join "`r`n")
}

# -- Remote suite runner --------------------------------------------------------
# Push the batch to the VM via schtasks /s, poll markers on TAShare.
# When AutoRecover is 'true', detects Trigger A (RDP-drop signature) and Trigger B (45-min idle)
# and automatically recovers the VM, retrying only the affected TCs - capped at 2 recoveries.
# Returns { LogDir, CoreLog }.
function Invoke-SuiteRun ([string]$Base, [string]$SuiteName, [string]$BatName,
                           [array]$Tests, [string]$HtmlDir, [bool]$ClearLogs = $true,
                           [string]$RecoveryEnabled = 'true') {
    $maxRecoveries  = 2
    $recoveryCount  = 0
    $currentTests   = $Tests
    $isFirstAttempt = $true

    while ($true) {
        # Unique token for this attempt - prevents a stale finished.txt from a prior/overlapping run
        # from triggering a false finish. The poll loop only breaks when it reads back THIS exact token.
        $taskName  = "Cobol2c.Runner_${SuiteName}_${Machine}_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        $localBat  = Join-Path $env:TEMP $BatName
        $vmBatPath = "C:\Apps\TA-CMD\$BatName"
        Set-Content -Path $localBat -Value (New-TABatch $Base $currentTests $isLogging $HtmlDir $taskName $SuiteName $Ta01Pw) -Encoding Ascii

        # -- Clear log dir ------------------------------------------------------
        if ($isFirstAttempt -and $ClearLogs) {
            # Full clear on the first attempt when requested
            if (Test-Path -LiteralPath $HtmlDir) {
                Get-ChildItem -LiteralPath $HtmlDir -Recurse -File |
                    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
                Get-ChildItem -LiteralPath $HtmlDir -Recurse -Directory |
                    Sort-Object -Property FullName -Descending |
                    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
            }
            $null = New-Item -ItemType Directory -Force -Path $HtmlDir
        } else {
            # Recovery attempt (or ClearLogs=$false first pass): preserve unaffected TCs' results.
            # Delete only the affected TCs' stale HTML + exec logs so triage sees exactly one HTML
            # per TC, then reset the run markers.
            if (-not (Test-Path -LiteralPath $HtmlDir)) { $null = New-Item -ItemType Directory -Force -Path $HtmlDir }
            foreach ($t in $currentTests) {
                Get-ChildItem -LiteralPath $HtmlDir -Filter '*.html' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match "^$([regex]::Escape($t.tc))(?!\d)" } |
                    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
                Remove-Item -LiteralPath (Join-Path $HtmlDir "ta-exec-$($t.tc).log") -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath (Join-Path $HtmlDir 'started.txt')  -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath (Join-Path $HtmlDir 'finished.txt') -Force -ErrorAction SilentlyContinue
        }
        $isFirstAttempt = $false

        # -- Push batch and poll ------------------------------------------------
        $startedFile     = Join-Path $HtmlDir 'started.txt'
        $finishedFile    = Join-Path $HtmlDir 'finished.txt'
        $overallDeadline = (Get-Date).AddMinutes(45)
        $hardDeadline    = (Get-Date).AddMinutes(90)
        $idleLimit       = [TimeSpan]::FromMinutes(45)
        $lastMtime       = $null
        $lastProgress    = Get-Date

        $completed     = $false
        $wedged        = $false
        $affectedTests = @()
        $wedgeTail     = ''
        $runStart      = $null

        try {
            Connect-VmShare   -Machine $Machine -Ta01Pw $Ta01Pw
            Copy-BatToVm      -Machine $Machine -BatPath $localBat
            Invoke-RemoteTask -Machine $Machine -Ta01Pw $Ta01Pw -TaskName $taskName -BatPath $vmBatPath

            $runStart = Get-Date

            # -- Poll for started.txt -> finished.txt on TAShare -----------------
            # Trigger B: started.txt idle for 45+ min = TACommandExecutor likely crashed.
            # Hard 90-min cap - break regardless after 90 min.
            while ((Get-Date) -lt $hardDeadline) {
                if (Test-Path -LiteralPath $finishedFile) {
                    $fin = (Get-Content -LiteralPath $finishedFile -Raw -ErrorAction SilentlyContinue)
                    if ($fin -and $fin.Trim() -eq $taskName) { $completed = $true; break }
                }

                if (Test-Path -LiteralPath $startedFile) {
                    $item = Get-Item -LiteralPath $startedFile -ErrorAction SilentlyContinue
                    if ($item -and $item.LastWriteTime -ne $lastMtime) {
                        $lastMtime    = $item.LastWriteTime
                        $lastProgress = Get-Date
                    }
                    # Trigger B: started.txt unchanged for 45+ min - TACommandExecutor likely crashed
                    if ($lastMtime -and ((Get-Date) - $lastProgress) -gt $idleLimit) {
                        $wedgeTail     = (Get-Content -LiteralPath $startedFile -Tail 1 -ErrorAction SilentlyContinue)
                        $affectedTests = Get-AffectedTests -Trigger 'B' -LogDir $HtmlDir `
                                                           -StartedTail $wedgeTail -AllTests $currentTests
                        $wedged = $true
                        break
                    }
                } elseif ((Get-Date) -gt $overallDeadline) {
                    break   # batch never launched; handled below
                }

                Start-Sleep -Seconds 5
            }
        } finally {
            # Always clean up the remote task and SMB session - regardless of success or failure
            Remove-RemoteTask -Machine $Machine -Ta01Pw $Ta01Pw -TaskName $taskName
            Remove-Item -LiteralPath $localBat -Force -ErrorAction SilentlyContinue
        }

        # -- Trigger A check (after a completed poll) ---------------------------
        # A run that finished normally but left RDP-drop signature in the results means
        # the desktop lost rendering partway through - those TCs need a re-run.
        if (-not $wedged -and $completed) {
            if (Test-RdpDropSignature -LogDir $HtmlDir) {
                $affectedTests = Get-AffectedTests -Trigger 'A' -LogDir $HtmlDir `
                                                   -StartedTail '' -AllTests $currentTests
                $wedged = $true
            }
        }

        # -- Recovery / throw on wedge ------------------------------------------
        if ($wedged) {
            $affectedTcList = ($affectedTests | ForEach-Object { $_.tc }) -join ', '
            if (-not $affectedTcList) { $affectedTcList = ($currentTests | ForEach-Object { $_.tc }) -join ', ' }

            if (($RecoveryEnabled -eq 'true') -and $recoveryCount -lt $maxRecoveries) {
                $triggerDesc = if ($wedgeTail) { 'Trigger B (TACommandExecutor crash)' }
                               else            { 'Trigger A (RDP-drop signature)' }
                Write-Warning ("[$SuiteName] VM WEDGED on ${Machine} - $triggerDesc. " +
                               "Recovery $($recoveryCount + 1)/$maxRecoveries. " +
                               "Affected TCs: $affectedTcList. Rebooting VM and retrying...")
                Invoke-VMRecovery -Machine $Machine -Ta01Pw $Ta01Pw -TaskName $taskName
                $recoveryCount++
                if ($affectedTests.Count -gt 0) { $currentTests = $affectedTests }
                continue   # retry with narrowed TC set
            }

            $capMsg = if ($RecoveryEnabled -eq 'true') { "Auto-recovery cap ($maxRecoveries) reached. " } else { '' }
            $triggerMsg = if ($wedgeTail) {
                "started.txt unchanged for 45+ min - TACommandExecutor likely crashed. Last line: $wedgeTail."
            } else {
                "RDP-drop signature detected after run completion - interactive desktop stopped rendering."
            }
            throw ("[$SuiteName] VM WEDGED on ${Machine}: $triggerMsg " +
                   "Affected TCs: $affectedTcList. ${capMsg}" +
                   "RDP to ${Machine} as TA01, unlock/reboot the VM, and retry the job.")
        }

        # -- Timeout check ------------------------------------------------------
        if (-not $completed) {
            $started = Test-Path -LiteralPath $startedFile
            $hint    = if ($started) {
                "started.txt found - batch launched but did not complete within the time limit."
            } else {
                "started.txt never appeared - batch may have failed to launch, or the TA01 desktop is locked."
            }
            throw "[$SuiteName] Timed out on $Machine. $hint"
        }

        # -- Validate that ta execute produced result files ---------------------
        # finished.txt is only accepted when it contains our run token, so we only reach here after
        # the real batch completed; no SMB-cache sleep needed.
        $htmlCount = @(Get-ChildItem -LiteralPath $HtmlDir -Filter '*.html' -File -ErrorAction SilentlyContinue).Count
        if ($htmlCount -eq 0) {
            $dirContents = (@(Get-ChildItem -LiteralPath $HtmlDir -File -ErrorAction SilentlyContinue |
                              ForEach-Object { $_.Name }) -join ', ')
            if (-not $dirContents) { $dirContents = '(empty)' }
            $logHint = (Get-ChildItem -LiteralPath $HtmlDir -Filter 'ta-exec-*.log' -File -ErrorAction SilentlyContinue |
                        Select-Object -First 1 | ForEach-Object { $_.FullName })
            $logHint = if ($logHint) { " First error log: $logHint" } else { '' }
            throw ("[$SuiteName] ran on ${Machine} but produced 0 result HTML files " +
                   "(expected $($currentTests.Count)).${logHint} " +
                   "Dir contents at check time: [$dirContents]. " +
                   "TA execute likely failed - check ta-exec-*.log files in $HtmlDir.")
        }

        # -- Collect the CoreLog from TAShare -----------------------------------
        $coreLog = $null
        if ($isLogging) {
            $coreLogDir = Join-Path $HtmlDir 'CoreLogs'
            if (Test-Path -LiteralPath $coreLogDir) {
                $coreLog = Get-ChildItem -LiteralPath $coreLogDir -Filter 'CoreLog*.glog' -File `
                               -ErrorAction SilentlyContinue |
                           Where-Object   { $_.LastWriteTime -ge $runStart } |
                           Sort-Object    LastWriteTime -Descending |
                           Select-Object  -First 1 |
                           ForEach-Object { $_.FullName }
            }
        }

        return [pscustomobject]@{
            LogDir  = $HtmlDir
            CoreLog = $coreLog
        }
    }
}

# -- Preflight, TC manifest, and execution --------------------------------------
# Guard: skip when dot-sourced by Pester (InvocationName = '.').
# Dot-sourcing loads the module imports, script-level variables, and function definitions
# so tests can call Invoke-SuiteRun / New-TABatch directly with their own $tests array.
if ($MyInvocation.InvocationName -ne '.') {
    # Preflight - fail fast with a specific, actionable message before any push attempt.
    # Prevents "VM down" from being misread as EDR blocking or a missing share.
    Assert-VmReady -Machine $Machine -Ta01Pw $Ta01Pw

    # Pre-batch reboot: start each batch from a clean boot state.
    # Reboots the VM, waits for the Apps share to return, and re-logs in TA01.
    # Adds ~5-10 min but eliminates stale-session and leftover-process false positives.
    if ($rebootBeforeRun) {
        [Console]::Error.WriteLine("[$Machine] Pre-batch reboot - rebooting before running suites...")
        Invoke-VmReboot -Machine $Machine -Ta01Pw $Ta01Pw
        # Re-probe: confirm the VM is fully up before handing off to the suite runners.
        Assert-VmReady -Machine $Machine -Ta01Pw $Ta01Pw
        [Console]::Error.WriteLine("[$Machine] VM back online - proceeding with suites.")
    }

    # TC manifest - looked up in order: script directory first (shipped with the runner), then TAShare.
    $manifestPath = Join-Path $scriptDir 'tc-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        $manifestPath = Join-Path $FailBase 'tc-manifest.json'
    }
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw ("TC manifest not found in script dir or TAShare ($FailBase).`n" +
               "Add tc-manifest.json (array of {tc, rep, prj, path} objects) next to Invoke-TaRun.ps1.`n" +
               "Use ta_generate_execute_bat MCP tool in Claude to resolve TC paths.")
    }
    $manifestMap = @{}
    (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json) |
        ForEach-Object { $manifestMap[$_.tc] = $_ }

    $tests = @(foreach ($tc in $tcNums) {
        if (-not $manifestMap.ContainsKey($tc)) {
            throw "TC $tc not found in $manifestPath - add it ({tc, rep, prj, path}) using ta_generate_execute_bat."
        }
        $manifestMap[$tc]
    })

    # Run both suites sequentially.
    # Failing suite (Cobol2C) first - pushes its Bin/Plugins to the VM.
    # Reference suite (SP2V6) second - overwrites Bin/Plugins with originals, runs same TCs.
    $ts      = Get-Date -Format 'yyyyMMdd_HHmmss'
    $failBat = "${Machine}_${Suite}_${ts}_a0.bat"
    $refBat  = "${Machine}_${RefSuite}_${ts}_a0.bat"

    $failRun = Invoke-SuiteRun -Base $FailBase -SuiteName $Suite    -BatName $failBat `
                                -Tests $tests  -HtmlDir $FailLogDir  -ClearLogs $doClear `
                                -RecoveryEnabled $autoRecover
    $refRun  = Invoke-SuiteRun -Base $RefBase  -SuiteName $RefSuite -BatName $refBat  `
                                -Tests $tests  -HtmlDir $RefLogDir   -ClearLogs $doClear `
                                -RecoveryEnabled $autoRecover

    # Emit TaRunResult JSON to stdout (deserialized by PowerShellHost)
    [pscustomobject]@{
        FailLogDir      = $failRun.LogDir
        RefLogDir       = $refRun.LogDir
        FailCoreLogPath = $failRun.CoreLog
        RefCoreLogPath  = $refRun.CoreLog
    } | ConvertTo-Json -Depth 5
}
