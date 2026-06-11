<#
.SYNOPSIS
Real TA execution wrapper — for the GSS network box only.
Reuses the run-ta-tests skill logic (schtasks, SMB, TA CLI) to run tests on a TA VM
and returns a TaRunResult JSON object to stdout (consumed by PowerShellTaExecutor).

NOT used in the PoC (MockTaExecutor returns fixture paths instead).
Only functional when the runner is deployed on a box with:
  - VPN / GSS network access
  - Credentials for the TA VMs (GSSTester / TA01) in env or config
  - Access to \\gss2k19rnd.gss.local\TAShare

.PARAMETER Suite    "Cobol2C" | "SP2V6" | "Production"
.PARAMETER Machine  VM name, e.g. "TGFTA-57" (FQDN resolved internally)
.PARAMETER Tcs      Comma-separated TC numbers, e.g. "27510,27511"
.PARAMETER Logging  "true" | "false"
#>
param(
    [string]$Suite,
    [string]$Machine,
    [string]$Tcs,
    [string]$Logging = 'true',
    [string]$Ta01Pw     # Password for TGFTA-###\TA01 — same across all machines
)

# Username is always derived from the machine name — never needs to be passed separately.
$ta01User = "$Machine\TA01"

$ErrorActionPreference = 'Stop'

# Emit UTF-8 to the redirected pipe so C# reads it correctly on both PS 5.1 and PS 7.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# --- PLACEHOLDER: implement from run-ta-tests/SKILL.md when deploying to the GSS box ---
# Key steps to port:
#   1. Resolve VM FQDN: "${Machine}.gss.local" (VMs are not domain-joined)
#   2. Stop GssSystemIntegrityService on the VM (else new programs roll back)
#   3. Use MCP ta_generate_execute_bat to resolve TC → repo/project/treepath
#   4. Write the TA execute batch to \\gss2k19rnd.gss.local\TAShare\<Suite>\Cmd\
#   5. Copy to \\<FQDN>\Apps\TA-CMD and launch via schtasks /it (interactive session)
#   6. Poll \\<FQDN>\Apps\... for started.txt / finished.txt markers
#   7. Find the CoreLog written at/after tcStart in \\<FQDN>\Apps\Global\Files\AutoTrace\
#   8. Return paths via JSON

# Credentials must come from environment/secrets — NEVER hardcode them here.
# In production: read from $env:TA_GSSTESTER_PW and $env:TA_TA01_PW (Launchpad secrets).

throw "Invoke-TaRun.ps1 is not implemented. Deploy to the GSS network box and port from run-ta-tests/SKILL.md."
