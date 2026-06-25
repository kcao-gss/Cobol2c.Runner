<#
.SYNOPSIS
Local TA execution for the pull-agent (no SMB, no UNC, no schtasks /s).
Ported directly from Invoke-TaRun.ps1 New-TABatch/Invoke-SuiteRun; UNC replaced by LocalBase.
Emits TaRunResult JSON to stdout for PowerShellHost to deserialize.

.PARAMETER Suite        Failing suite, e.g. Cobol2C
.PARAMETER Tcs          Comma-separated TC numbers, e.g. 27510,27511
.PARAMETER Logging      true | false
.PARAMETER ManifestPath Absolute path to tc-manifest.json ({tc,rep,prj,path} format)
.PARAMETER LocalBase    Local TAShare root -- has <Suite>\Bin and <Suite>\Plugins subdirs
.PARAMETER HtmlDir      Output dir for markers + HTML. Defaults to per-run temp dir.
#>
param(
    [string]$Suite,
    [string]$Tcs,
    [string]$Logging      = 'true',
    [string]$ManifestPath,
    [string]$LocalBase,
    [string]$HtmlDir      = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# --- parse Tcs ---
$tcNums    = @($Tcs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$isLogging = $Logging -eq 'true'

# --- load manifest ({tc, rep, prj, path} -- same format as Invoke-TaRun.ps1) ---
if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "TC manifest not found: $ManifestPath"
}
$manifestMap = @{}
(Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json) |
    ForEach-Object { $manifestMap[$_.tc] = $_ }

$tests = @(foreach ($tc in $tcNums) {
    if (-not $manifestMap.ContainsKey($tc)) {
        throw "TC $tc not found in $ManifestPath -- add it ({tc, rep, prj, path}) using ta_generate_execute_bat."
    }
    $manifestMap[$tc]
})

if ([string]::IsNullOrWhiteSpace($HtmlDir)) {
    $HtmlDir = Join-Path $env:TEMP ("Cobol2c.Agent_" + $Suite + "_" + (Get-Date -Format 'yyyyMMdd_HHmmss'))
}
$null = New-Item -ItemType Directory -Force -Path $HtmlDir

# ===========================================================================
# New-TABatch: ported from Invoke-TaRun.ps1.
# Changes: Base is local path not UNC; RunToken written to finished.txt.
# Uses real tc-manifest fields: {tc, rep, prj, path}
# ===========================================================================
function New-TABatch ([string]$Base, [array]$Tests, [bool]$IsLogging,
                      [string]$HtmlDir, [string]$RunToken) {
    $kw      = if ($IsLogging) { 'new program,batch,2023,log,without service' }
               else             { 'new program,batch,2023,without service' }
    $html    = $HtmlDir
    $tcLabel = ($Tests | ForEach-Object { $_.tc }) -join ', '
    $esc     = { param($s) (($s -replace '\^','^^') -replace '([&<>|()])',(('^') + '$1')) -replace '%','%%' }
    $capArgs = ''
    $L2 = [System.Collections.Generic.List[string]]::new()

    $L2.Add('@echo off')
    $L2.Add('title TestArchitect - Command Line Tool')
    $L2.Add('chcp.com 65001 >nul')
    $L2.Add("REM LocalBase: $Base   Logging: $IsLogging   TCs: $tcLabel")
    $L2.Add('')
    $L2.Add('set LS=172.16.43.66:8778')
    $L2.Add('set RS=172.16.43.66:53400')
    $L2.Add('set USER=GSSTester')
    $L2.Add('set PASS=04848555D4C')
    $L2.Add("set KEYWORDS=$kw")
$L2.Add('set STARTUP=env file path=uds=\\\\172.16.60.6\\Artifacts\\LG-Automation Data\\Env setup\\logigear env.xml')
    $L2.Add('set HARNESS_FWD=C:/GSS Harness/run.bat')
    $L2.Add("set HARNESS_CMD='C:\GSS Harness\run.bat'")
    $L2.Add("set HTML=$html")
    $L2.Add('set UDF=build number=')
    if ($IsLogging) {
        $L2.Add('set CAPTURECOND=Failed')
        $L2.Add('set CAPTURELIMIT=3')
        $capArgs = ' -cc "%CAPTURECOND%" -cl "%CAPTURELIMIT%"'
    }
    $L2.Add('')
    $L2.Add('if not exist "%HTML%" mkdir "%HTML%"')
    $L2.Add('REM 1) mark start; per-TC lines appended below')
    $L2.Add('echo [%DATE% %TIME%] BATCH STARTED - deploying updated programs> "%HTML%\started.txt"')
    $L2.Add('REM 2) stop integrity service so it cannot roll back the updated programs')
    $L2.Add('echo Y| net stop "GssSystemIntegrityService" > "%HTML%\service-stop.log" 2>&1')
    $L2.Add('REM 3) deploy updated programs from LocalBase')
    $L2.Add(('robocopy "{0}\Bin" "C:\Apps\Global\Bin" /E /R:1 /W:1 /NP > "%HTML%\copy-bin.log" 2>&1' -f $Base))
    $L2.Add('REM 3b) no machine-specific Bin in local mode')
    $L2.Add('REM 4) deploy plugins')
    $L2.Add(('robocopy "{0}\Plugins" "C:\Apps\Global\Plugins" /E /R:1 /W:1 /NP > "%HTML%\copy-plugins.log" 2>&1' -f $Base))
    $L2.Add('REM 5) unblock mark-of-the-web on the copied programs')
    $L2.Add('powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath ''C:\Apps\Global\Bin'' -Recurse -File | Unblock-File" > "%HTML%\unblock-bin.log" 2>&1')
    $L2.Add('')
    foreach ($t in $Tests) {
        $leaf   = ($t.path -split '/')[-1]
        $status = & $esc ("Running TC {0} [{1}/{2}]: {3}" -f $t.tc, $t.rep, $t.prj, $leaf)
        $rname  = ($leaf -replace '\s*\{[^}]*\}', '').Trim()
        $cmd    = ('ta execute -ls "%LS%" -rep "{0}" -prj "{1}" -u "%USER%" -p "%PASS%" -t "{2}" -rs "%RS%" -ss "%STARTUP%" -kwd "%KEYWORDS%" -tscript "%HARNESS_FWD%" -tcmd "%HARNESS_CMD%" -tpath "%HARNESS_FWD%" -html "%HTML%" -subfld "0" -subhtml "0" -udf "%UDF%"{4} -r "{3}" -up "/{1}/Results/ManualRuns/{{year}}_{{month}}_{{day}}"' -f
                   $t.rep, $t.prj, $t.path, $rname, $capArgs)
        $L2.Add("REM --- TC $($t.tc) ---")
        $L2.Add("echo [%DATE% %TIME%] $status>> `"%HTML%\started.txt`"")
        $L2.Add("$cmd > `"%HTML%\ta-exec-$($t.tc).log`" 2>&1")
        $L2.Add('')
    }
    $L2.Add('REM Copy CoreLog to log folder (/COPY:D preserves LastWriteTime)')
    $L2.Add('if exist "C:\Apps\Global\Files\AutoTrace" robocopy "C:\Apps\Global\Files\AutoTrace" "%HTML%\CoreLogs" CoreLog*.glog /R:1 /W:1 /NP /COPY:D >nul 2>&1')
    $L2.Add("echo ${RunToken}>`"%HTML%\finished.txt`"")
    return ($L2 -join "`r`n")
}

# ===========================================================================
# Start-LocalBatch  <-- mockable seam for unit tests
# Single-string -ArgumentList avoids the leading-space bug from array form.
# ===========================================================================
function Start-LocalBatch {
    param([string]$BatPath, [string]$HtmlDir)
    $argStr = "/c `"$BatPath`""
    Start-Process -FilePath 'cmd.exe' -ArgumentList $argStr -WorkingDirectory $HtmlDir -NoNewWindow -Wait
}

# ===========================================================================
# Wait-ForMarker: ported from Invoke-SuiteRun poll loop.
# Only returns Completed when finished.txt contains the EXACT RunToken.
# Returns: 'Completed' | 'Idle' | 'TimedOut'
# ===========================================================================
function Wait-ForMarker {
    param(
        [string]$HtmlDir,
        [string]$RunToken,
        [int]$HardDeadlineSec = 7200,
        [int]$IdleLimitSec    = 2700,
        [int]$PollMs          = 5000
    )
    $deadline  = (Get-Date).AddSeconds($HardDeadlineSec)
    $idleLimit = [TimeSpan]::FromSeconds($IdleLimitSec)
    $startedF  = Join-Path $HtmlDir 'started.txt'
    $finishedF = Join-Path $HtmlDir 'finished.txt'
    $lastMtime    = $null
    $lastProgress = Get-Date

    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $finishedF) {
            try {
                $fin = Get-Content -LiteralPath $finishedF -Raw -ErrorAction SilentlyContinue
                if ($fin -and $fin.Trim() -eq $RunToken) { return 'Completed' }
            } catch { }
        }

        if (Test-Path -LiteralPath $startedF) {
            try {
                $item = Get-Item -LiteralPath $startedF -ErrorAction SilentlyContinue
                if ($item -and $item.LastWriteTime -ne $lastMtime) {
                    $lastMtime    = $item.LastWriteTime
                    $lastProgress = Get-Date
                }
                if ($lastMtime -and ((Get-Date) - $lastProgress) -gt $idleLimit) {
                    return 'Idle'
                }
            } catch { }
        }
        Start-Sleep -Milliseconds $PollMs
    }
    return 'TimedOut'
}

# ===========================================================================
# Main: generate run-token, build batch, launch, poll, throw on failure,
# collect CoreLog, emit TaRunResult JSON to stdout.
# ===========================================================================

# Unique run token -- same anti-staleness pattern as Invoke-SuiteRun $taskName.
# The batch writes this exact token to finished.txt as its last step.
# The poller only treats the run as done when it reads back this token.
$runToken = "Cobol2c.Agent_${Suite}_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

# LocalBase layout mirrors TAShare: $LocalBase\$Suite\Bin, $LocalBase\$Suite\Plugins
$base = Join-Path $LocalBase $Suite

$batPath    = Join-Path $HtmlDir "${Suite}_local_run.bat"
$batContent = New-TABatch -Base $base -Tests $tests -IsLogging $isLogging `
                         -HtmlDir $HtmlDir -RunToken $runToken
Set-Content -Path $batPath -Value $batContent -Encoding Ascii

$runStart = Get-Date

Start-LocalBatch -BatPath $batPath -HtmlDir $HtmlDir

$outcome = Wait-ForMarker -HtmlDir $HtmlDir -RunToken $runToken `
                         -HardDeadlineSec 7200 -IdleLimitSec 2700 -PollMs 5000

# Non-Completed outcomes THROW (not silently swallowed) so the agent POSTs a failure.
if ($outcome -eq 'Idle') {
    $tail = Get-Content -LiteralPath (Join-Path $HtmlDir 'started.txt') -Tail 1 -ErrorAction SilentlyContinue
    throw "[$Suite] LOCAL RUN IDLE: started.txt unchanged for 45+ min. Last line: $tail. Check $HtmlDir."
}
if ($outcome -ne 'Completed') {
    $started = Test-Path -LiteralPath (Join-Path $HtmlDir 'started.txt')
    $hint    = if ($started) { 'started.txt found -- batch launched but did not complete within the time limit.' }
               else          { 'started.txt never appeared -- batch failed to launch.' }
    throw "[$Suite] LOCAL RUN TIMED OUT. $hint Check $HtmlDir for logs."
}

# Collect CoreLog (same logic as Invoke-SuiteRun)
$coreLog = $null
if ($isLogging) {
    $coreLogDir = Join-Path $HtmlDir 'CoreLogs'
    if (Test-Path -LiteralPath $coreLogDir) {
        $cl = Get-ChildItem -LiteralPath $coreLogDir -Filter 'CoreLog*.glog' -File `
                  -ErrorAction SilentlyContinue |
              Where-Object   { $_.LastWriteTime -ge $runStart } |
              Sort-Object    LastWriteTime -Descending |
              Select-Object  -First 1
        # Explicit coercion: must be [string] or $null -- never a FileInfo or empty collection.
        # An empty pipeline result can become a non-null object that ConvertTo-Json renders as {}.
        $coreLog = if ($cl) { [string]$cl.FullName } else { $null }
    }
}

# Emit TaRunResult JSON to stdout (PowerShellHost deserializes this).
# Slice-0: one suite; RefLogDir = HtmlDir (same run), RefCoreLogPath = same CoreLog.
[pscustomobject]@{
    FailLogDir      = $HtmlDir
    RefLogDir       = $HtmlDir
    FailCoreLogPath = $coreLog
    RefCoreLogPath  = $coreLog
} | ConvertTo-Json -Depth 5