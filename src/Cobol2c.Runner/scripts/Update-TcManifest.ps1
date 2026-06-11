<#
.SYNOPSIS
Adds or refreshes TC entries in tc-manifest.json by resolving their TA repository paths
directly via the TestArchitect MCP server. No Claude session required — just run the script.

.DESCRIPTION
Uses the OAuth refresh token stored by Claude Code (.claude/.credentials.json) to get a fresh
access token, then calls the TestArchitect MCP's ta_generate_execute_bat tool to look up each
TC's repository, project, and full tree path, and merges the results into tc-manifest.json.

Requires: TestArchitect MCP authenticated at least once via /mcp in Claude Code.

.PARAMETER Tcs
One or more TC numbers to add/update. Can be a comma-separated string or an array.

.EXAMPLE
.\Update-TcManifest.ps1 -Tcs 27510,27511,27514
.\Update-TcManifest.ps1 -Tcs @('27510','27511')
#>
param(
    [Parameter(Mandatory)][string[]]$Tcs
)

$ErrorActionPreference = 'Stop'

# ── Load TestArchitect OAuth refresh token from Claude Code credentials ───────
$credPath = Join-Path $env:USERPROFILE '.claude\.credentials.json'
if (-not (Test-Path -LiteralPath $credPath)) {
    throw "Claude Code credentials not found at $credPath.`nAuthenticate TestArchitect once via /mcp in Claude Code, then re-run."
}

$creds   = Get-Content -LiteralPath $credPath -Raw | ConvertFrom-Json
$taEntry = $creds.mcpOAuth.PSObject.Properties |
           Where-Object { $_.Value.serverUrl -like '*testarchitect-mcp*' } |
           Select-Object -First 1

if (-not $taEntry) {
    throw "TestArchitect MCP credentials not found in $credPath.`nRun /mcp in Claude Code and authenticate TestArchitect, then re-run."
}

$refreshToken = $taEntry.Value.refreshToken
if (-not $refreshToken) { throw "TestArchitect refresh token is empty — re-authenticate via /mcp." }

# ── Exchange refresh token for a fresh access token ───────────────────────────
$tokenEndpoint = 'https://auth3.globalshopsolutions.dev/auth/realms/global-shop-solutions/protocol/openid-connect/token'
$tokenBody     = "grant_type=refresh_token&client_id=mcp-client&refresh_token=$([uri]::EscapeDataString($refreshToken))"
$tokenResp     = Invoke-RestMethod -Method Post -Uri $tokenEndpoint `
                     -ContentType 'application/x-www-form-urlencoded' -Body $tokenBody
$accessToken   = $tokenResp.access_token

# ── Open an MCP session and call ta_generate_execute_bat ──────────────────────
$mcpUrl  = 'https://testarchitect-mcp.globalshopsolutions.dev/mcp'
$headers = @{
    'Authorization' = "Bearer $accessToken"
    'Content-Type'  = 'application/json'
    'Accept'        = 'application/json, text/event-stream'
}

function Invoke-Mcp ([hashtable]$Body) {
    $json = $Body | ConvertTo-Json -Depth 10 -Compress
    $resp = Invoke-WebRequest -Method Post -Uri $mcpUrl -Headers $script:headers -Body $json -UseBasicParsing
    # Add session ID to all subsequent requests once the server issues one
    if ($resp.Headers['Mcp-Session-Id'] -and -not $script:headers['Mcp-Session-Id']) {
        $script:headers['Mcp-Session-Id'] = $resp.Headers['Mcp-Session-Id']
    }
    $ct = $resp.Headers['Content-Type']
    if ($ct -like '*event-stream*') {
        # SSE: pull the last data: line that contains a JSON object
        $data = ($resp.Content -split "`n" |
                 Where-Object { $_ -match '^data:\s*\{' } |
                 Select-Object -Last 1) -replace '^data:\s*',''
        return $data | ConvertFrom-Json
    }
    return $resp.Content | ConvertFrom-Json
}

# Initialize
$null = Invoke-Mcp @{
    jsonrpc = '2.0'; id = 0; method = 'initialize'
    params  = @{
        protocolVersion = '2024-11-05'
        capabilities    = @{}
        clientInfo      = @{ name = 'Update-TcManifest'; version = '1.0' }
    }
}
# Notify initialized (required by MCP spec after initialize)
$null = Invoke-Mcp @{ jsonrpc = '2.0'; method = 'notifications/initialized'; params = @{} }

# Call the tool
$toolResp   = Invoke-Mcp @{
    jsonrpc = '2.0'; id = 1; method = 'tools/call'
    params  = @{
        name      = 'ta_generate_execute_bat'
        arguments = @{ test_case_numbers = @($Tcs) }
    }
}
$batResult = $toolResp.result.content[0].text | ConvertFrom-Json

if (-not $batResult.success) {
    throw "ta_generate_execute_bat failed. Check the TC numbers."
}
if ($batResult.notFoundCount -gt 0 -or $batResult.pathNotResolvedCount -gt 0) {
    $found = $batResult.resolvedCount; $total = $batResult.totalRequested
    throw "$($total - $found) of $total TCs could not be resolved. Check the numbers and try again."
}

# ── Parse the batch content → manifest entries ────────────────────────────────
# The batch has paired lines: "REM --- TC <num>: ..." then "ta execute ... -rep ... -prj ... -t ..."
$entries  = @{}
$currentTc = $null
foreach ($line in ($batResult.batContent -split "`r?`n")) {
    if ($line -match '^REM --- TC (\d+)') {
        $currentTc = $matches[1]
        continue
    }
    if ($line -match '^ta execute ' -and $currentTc) {
        $rep = if ($line -match '-rep "([^"]+)"') { $matches[1] } else { '' }
        $prj = if ($line -match '-prj "([^"]+)"') { $matches[1] } else { '' }
        $pth = if ($line -match ' -t "([^"]+)"')  { $matches[1] } else { '' }
        $entries[$currentTc] = [pscustomobject]@{ tc = $currentTc; rep = $rep; prj = $prj; path = $pth }
        $currentTc = $null
    }
}

if ($entries.Count -eq 0) { throw "Could not parse any ta execute lines from the batch output." }

# ── Merge into tc-manifest.json ───────────────────────────────────────────────
$manifestPath = Join-Path $PSScriptRoot 'tc-manifest.json'
$existing = if (Test-Path -LiteralPath $manifestPath) {
    @(Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json)
} else { @() }

$merged = @{}
foreach ($e in $existing)          { $merged[$e.tc] = $e }
foreach ($e in $entries.Values)    { $merged[$e.tc] = $e }

$sorted = $merged.Values | Sort-Object { [int]$_.tc }
$sorted | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

Write-Host "tc-manifest.json updated: added/refreshed $($entries.Count) TC(s) — $($entries.Keys -join ', ')"
Write-Host "Total entries: $($merged.Count)"
