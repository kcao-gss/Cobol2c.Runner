# console-park.ps1
# VM-side helper - runs as SYSTEM via a scheduled task created by Enter-ConsoleSession.
# Parses qwinsta to find TA01's session id, parks it onto the physical console via tscon,
# and logs the result to C:\Windows\Temp\park.log so the controller can verify success.
# Also writes to C:\Apps\TA-CMD\park.log (readable via \\<vm>\Apps\TA-CMD\park.log)
# when C$ is not accessible on the controller (non-domain workgroup VM config).
#
# Why tscon + SYSTEM: only SYSTEM can call tscon without the interactive-session restriction
# that would normally require the target session's own credentials.

$ErrorActionPreference = 'SilentlyContinue'
$logFile  = 'C:\Windows\Temp\park.log'
$logFile2 = 'C:\Apps\TA-CMD\park.log'   # fallback: readable via \\<vm>\Apps\TA-CMD\park.log

function Write-ParkLog {
    param([string]$Message, [switch]$New)
    if ($New) {
        $Message | Set-Content -LiteralPath $logFile  -ErrorAction SilentlyContinue
        $Message | Set-Content -LiteralPath $logFile2 -ErrorAction SilentlyContinue
    } else {
        $Message | Out-File -LiteralPath $logFile  -Append -ErrorAction SilentlyContinue
        $Message | Out-File -LiteralPath $logFile2 -Append -ErrorAction SilentlyContinue
    }
}

Write-ParkLog -Message ("=== console-park " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " ===") -New

# Capture raw qwinsta output (session list on the VM)
$qwinstaRaw = (qwinsta 2>&1)
$qwinstaRaw | ForEach-Object { Write-ParkLog $_ }

# Find the TA01 session line.
# qwinsta output has columns: SESSIONNAME, USERNAME, ID, STATE, TYPE, DEVICE
# A Disc (disconnected) session may have a blank SESSIONNAME field - the regex
# matches on USERNAME (ta01) in either field position and then extracts the
# leading numeric ID from the remaining text.
$ta01Line = $qwinstaRaw | Where-Object { $_ -match '(?i)\bta01\b' } | Select-Object -First 1

# Extract the session numeric ID from the line.
# For an active (connected) session the output is typically:
#   " >rdp-tcp#0        TA01            1  Active  rdpwd"
# For a disconnected session the SESSIONNAME column is blank so columns shift:
#   "                   TA01            2  Disc"
# In both cases the ID is the first standalone number after the username.
$sessionId = $null
if ($ta01Line) {
    # The qwinsta ID column is separated from USERNAME by two or more spaces.
    # Using a lookbehind on whitespace prevents matching the session-ordinal in
    # SESSIONNAME (e.g. the "0" in "rdp-tcp#0") which follows a non-space '#'.
    $m = [regex]::Match($ta01Line, '(?<=\s{2,})(\d+)(?=\s)')
    if ($m.Success) { $sessionId = $m.Groups[1].Value }
}

Write-ParkLog ("TA01 line=[" + $ta01Line + "] id=[" + $sessionId + "]")

if ($sessionId) {
    # Park the session onto the physical console so TA GUI rendering continues
    # with no RDP viewer attached.
    $tsconOut = (tscon $sessionId /dest:console 2>&1)
    Write-ParkLog ("tscon " + $sessionId + " /dest:console -> exit=" + $LASTEXITCODE + " out=" + $tsconOut)
} else {
    Write-ParkLog 'NO TA01 SESSION ID - tscon skipped'
}

# Brief pause then snapshot the post-park session list so the controller can confirm
Start-Sleep -Seconds 3
Write-ParkLog '--- post-park qwinsta ---'
(qwinsta 2>&1) | ForEach-Object { Write-ParkLog $_ }
