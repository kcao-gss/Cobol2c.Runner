<#
.SYNOPSIS
Real TA execution wrapper — for the GSS network box only.
Runs the specified TCs under the failing suite (e.g. Cobol2C) AND the SP2V6 reference suite on the
same VM, then emits a TaRunResult JSON object to stdout (consumed by PowerShellTaExecutor).

Requires:
  - VPN / GSS network access to \\gss2k19rnd.gss.local and \\<Machine>\Apps
  - \\gss2k19rnd.gss.local\TAShare\<Suite>\tc-manifest.json  (TC → rep/prj/treepath; see below)
  - TA01 logged in and desktop unlocked on the target VM
  - Runner__Ta01Pw env var set with the TA01 account password

TC manifest format (one-time setup, populate using ta_generate_execute_bat MCP tool):
  [ { "tc":"27510", "rep":"Inventory", "prj":"Inventory",
      "path":"/Production/2023 version/Inventory/Inventory Parts/27510_Inv_Add Cross Reference records {new program}" } ]

.PARAMETER Suite    Failing suite: "Cobol2C" | "SP2V6" | "Production"
.PARAMETER Machine  VM name, e.g. "TGFTA-118" (hostname used verbatim)
.PARAMETER Tcs      Comma-separated TC numbers, e.g. "27510,27511"
.PARAMETER Logging  "true" | "false"  (enables AutoTrace CoreLog capture; required for triage)
.PARAMETER Ta01Pw   Password for <Machine>\TA01 — same across all TGFTA-### machines
#>
param(
    [string]$Suite,
    [string]$Machine,
    [string]$Tcs,
    [string]$Logging = 'true',
    [string]$Ta01Pw
)

# Username is always derived from the machine name — never needs to be passed separately.
$ta01User  = "$Machine\TA01"   # machine-qualified for net use / schtasks /u
$RunAsUser = 'TA01'            # BARE name for schtasks /ru — machine-qualified fails SID lookup

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ── Parse inputs ──────────────────────────────────────────────────────────────
$tcNums    = @($Tcs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$isLogging = $Logging -eq 'true'
$RefSuite  = 'SP2V6'   # reference baseline: SP2V6 uses the original COBOL programs

$FailBase = "\\gss2k19rnd.gss.local\TAShare\$Suite"
$RefBase  = "\\gss2k19rnd.gss.local\TAShare\$RefSuite"
$ExecDir  = "\\$Machine\Apps\TA-CMD"
$TaskName = "TA_Run_$Machine"
$ts       = Get-Date -Format 'yyyyMMdd_HHmmss'

# ── TC manifest (TC number → rep / prj / treepath) ────────────────────────────
# One-time setup: use ta_generate_execute_bat MCP tool in Claude to resolve your TCs and save
# the result as tc-manifest.json on the TAShare. The runner reads it on every run.
$manifestPath = Join-Path $FailBase 'tc-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw ("TC manifest not found: $manifestPath`n" +
           "Create tc-manifest.json (array of {tc, rep, prj, path} objects) on the TAShare.`n" +
           "Use the ta_generate_execute_bat MCP tool in Claude to resolve the TCs, then save here.")
}
$manifestMap = @{}
(Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json) |
    ForEach-Object { $manifestMap[$_.tc] = $_ }

$tests = @(foreach ($tc in $tcNums) {
    if (-not $manifestMap.ContainsKey($tc)) {
        throw "TC $tc not found in $manifestPath — add it ({tc, rep, prj, path}) using ta_generate_execute_bat."
    }
    $manifestMap[$tc]
})

# ── Batch generator (ported from run-ta-tests/SKILL.md) ──────────────────────
function New-TABatch ([string]$Base, [array]$Tests, [bool]$IsLogging) {
    $kw      = if ($IsLogging) { 'new program,batch,2023,log,without service' }
               else             { 'new program,batch,2023,without service' }
    $html    = "$Base\Logs\$Machine"   # FQDN: VMs are not domain-joined; short name doesn't resolve
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
    $L.Add('echo [%DATE% %TIME%] BATCH STARTED - deploying updated programs> "%HTML%\started.txt"')
    $L.Add('echo Y| net stop "GssSystemIntegrityService" > "%HTML%\service-stop.log" 2>&1')
    $L.Add(('robocopy "{0}\Bin" "C:\Apps\Global\Bin" /E /R:1 /W:1 /NP > "%HTML%\copy-bin.log" 2>&1' -f $Base))
    $L.Add(('if exist "{0}\" (robocopy "{0}" "C:\Apps\Global\Bin" /E /R:1 /W:1 /NP > "%HTML%\copy-machine-bin.log" 2>&1) else (echo No machine-specific Bin: {0}> "%HTML%\copy-machine-bin.log")' -f "$Base\${Machine}Bin"))
    $L.Add(('robocopy "{0}\Plugins" "C:\Apps\Global\Plugins" /E /R:1 /W:1 /NP > "%HTML%\copy-plugins.log" 2>&1' -f $Base))
    $L.Add('powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath ''C:\Apps\Global\Bin'' -Recurse -File | Unblock-File" > "%HTML%\unblock-bin.log" 2>&1')
    $L.Add('')
    foreach ($t in $Tests) {
        $leaf   = ($t.path -split '/')[-1]
        $status = & $esc ("Running TC {0} [{1}/{2}]: {3}" -f $t.tc, $t.rep, $t.prj, $leaf)
        $cmd    = ('ta execute -ls "%LS%" -rep "{0}" -prj "{1}" -u "%USER%" -p "%PASS%" -t "{2}" -rs "%RS%" -ss "%STARTUP%" -kwd "%KEYWORDS%" -tscript "%HARNESS_FWD%" -tcmd "%HARNESS_CMD%" -tpath "%HARNESS_FWD%" -html "%HTML%" -subfld "0" -subhtml "0" -udf "%UDF%"{4} -r "{3}" -up "/{1}/Results/ManualRuns/{{year}}_{{month}}_{{day}}"' `
                          -f $t.rep, $t.prj, $t.path, $t.tc, $capArgs)
        $L.Add("REM --- TC $($t.tc) ---")
        $L.Add("echo [%DATE% %TIME%] $status>> `"%HTML%\started.txt`"")
        $L.Add($cmd)
        $L.Add('')
    }
    $L.Add('type nul > "%HTML%\finished.txt"')
    return ($L -join "`r`n")
}

# ── Run one suite on the machine ──────────────────────────────────────────────
function Invoke-SuiteRun ([string]$Base, [string]$SuiteName, [string]$BatName) {
    $CmdShare = "$Base\Cmd"
    $LogDir   = "$Base\Logs\$Machine"
    $bat      = Join-Path $ExecDir $BatName

    # Ensure the central Cmd folder exists on the TAShare (needed for SP2V6 if never used before)
    if (-not (Test-Path -LiteralPath $CmdShare)) {
        $null = New-Item -ItemType Directory -Force -Path $CmdShare
    }

    # Write batch to central Cmd archive (ASCII keeps it clean)
    Set-Content -Path (Join-Path $CmdShare $BatName) `
                -Value (New-TABatch $Base $tests $isLogging) `
                -Encoding Ascii

    # Stage copy on the VM
    $null = New-Item -ItemType Directory -Force -Path $ExecDir -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $CmdShare $BatName) -Destination (Join-Path $ExecDir $BatName) -Force

    # Clear the machine log folder so only this run's results and markers remain
    if (Test-Path -LiteralPath $LogDir) { Remove-Item -LiteralPath $LogDir -Recurse -Force }
    $null = New-Item -ItemType Directory -Force -Path $LogDir

    $runStart = Get-Date

    # Create + trigger the task (interactive /it so it runs in TA01's unlocked session)
    # /ru uses BARE 'TA01' — machine-qualified name fails SID lookup on workgroup VMs
    $out = schtasks /create /s $Machine /u $ta01User /p $Ta01Pw /tn $TaskName `
                    /tr "`"$bat`"" /sc ONCE /st 23:59 /ru $RunAsUser /it /rl HIGHEST /f 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "[$SuiteName] schtasks /create failed on $Machine (exit $LASTEXITCODE): $($out -join '; ')"
    }
    $out = schtasks /run /s $Machine /u $ta01User /p $Ta01Pw /tn $TaskName 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "[$SuiteName] schtasks /run failed on $Machine (exit $LASTEXITCODE): $($out -join '; ')"
    }

    # Poll for started.txt → finished.txt (45-minute timeout)
    $startedFile  = Join-Path $LogDir 'started.txt'
    $finishedFile = Join-Path $LogDir 'finished.txt'
    $deadline     = (Get-Date).AddMinutes(45)
    while (-not (Test-Path -LiteralPath $finishedFile) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
    }

    if (-not (Test-Path -LiteralPath $finishedFile)) {
        $hint = if (Test-Path -LiteralPath $startedFile) {
            "started.txt found — batch launched but did not complete within 45 min."
        } else {
            "started.txt never appeared — TA01 may not be logged in / desktop locked, or the task failed to launch."
        }
        throw "[$SuiteName] Timed out waiting for $Machine. $hint"
    }

    # Remove the task (best-effort; ignore errors)
    $null = schtasks /delete /s $Machine /u $ta01User /p $Ta01Pw /tn $TaskName /f 2>&1

    # Find the CoreLog file written at/after this run's start time
    $coreLog = $null
    if ($isLogging) {
        $atDir = "\\$Machine\Apps\Global\Files\AutoTrace"
        if (Test-Path -LiteralPath $atDir) {
            $coreLog = Get-ChildItem -LiteralPath $atDir -Filter 'CoreLog*.glog' -File `
                           -ErrorAction SilentlyContinue |
                       Where-Object   { $_.LastWriteTime -ge $runStart } |
                       Sort-Object    LastWriteTime -Descending |
                       Select-Object  -First 1 |
                       ForEach-Object { $_.FullName }
        }
    }

    return [pscustomobject]@{ LogDir = $LogDir; CoreLog = $coreLog }
}

# ── Authenticate to the VM's Apps share ───────────────────────────────────────
# Connects once; both suite runs use the same authenticated session.
$null = net use "\\$Machine\Apps" /user:$ta01User $Ta01Pw 2>&1

try {
    # Run failing suite (e.g. Cobol2C) first — programs deployed from its Bin/Plugins
    $failRun = Invoke-SuiteRun -Base $FailBase -SuiteName $Suite    -BatName "${Machine}_fail_${ts}.bat"
    # Run reference suite (SP2V6) second — programs deployed from its Bin/Plugins, overwriting above
    $refRun  = Invoke-SuiteRun -Base $RefBase  -SuiteName $RefSuite -BatName "${Machine}_ref_${ts}.bat"
} finally {
    $null = net use "\\$Machine\Apps" /delete 2>&1
}

# ── Emit TaRunResult JSON to stdout (deserialized by PowerShellHost) ──────────
[pscustomobject]@{
    FailLogDir      = $failRun.LogDir
    RefLogDir       = $refRun.LogDir
    FailCoreLogPath = $failRun.CoreLog
    RefCoreLogPath  = $refRun.CoreLog
} | ConvertTo-Json -Depth 5
