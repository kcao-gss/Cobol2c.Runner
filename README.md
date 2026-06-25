# Cobol2c.Runner — Windows Agent PoC

Automated triage runner for the COBOL→C# conversion pipeline.

**PoC scope:** test → triage → bug-report only (no auto-fix, no auto-commit).  
**Stack:** .NET 8 Worker Service (orchestration) + PowerShell (TA mechanics, reused from skills verbatim).

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8) | 8.x | Runtime only is NOT enough — you need the SDK to build |
| PowerShell | 5.1+ | **Windows PowerShell 5.1** ships in-box on all Windows (no install needed). [PowerShell 7+](https://github.com/PowerShell/PowerShell/releases) is also supported. Default config uses `pwsh`; see config table to switch. |
| [Pester](https://pester.dev/docs/introduction/installation) | 5.x | For PS unit tests only. PS 5.1 ships with legacy Pester 3 — install Pester 5 explicitly. |

Install SDK: `winget install Microsoft.DotNet.SDK.8`  
Install Pester 5: `Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck`  
On PS 5.1, load the right Pester before running: `Import-Module Pester -MinimumVersion 5.0`

## Quick Start

### Mock mode (local, no network, no VM)

```powershell
cd C:\Users\kcao\Projects\cobol-to-c#\Cobol2c.Runner

# 1. Build
dotnet build

# 2. Run all xUnit tests (invokes Invoke-Triage.ps1 against fixtures)
dotnet test

# 3. Run Pester PS unit tests (includes TaRemote, TaParsing, TaTrace, TaRecovery, TaRouting)
Invoke-Pester tests\pester -Output Detailed

# 4. Run the worker in mock mode (drains fixtures/jobs/, triage only, no real VM push)
$env:Runner__UseMocks = 'true'
dotnet run --project src\Cobol2c.Runner
#   Watch the console — it picks up job-INV010XR.json, runs triage against fixtures, writes:
#     out/job-INV010XR.json        (TriageResult)
#     out/job-INV010XR-report.md   (bug report)
#   The job file moves to fixtures/jobs/done/ when complete.

# Reset for another run (job file was moved to done/)
Copy-Item fixtures\jobs\done\job-INV010XR.json fixtures\jobs\
```

### Real mode (remote-push to a live VM)

Prerequisites:
1. VM is powered on with TA01 logged in and desktop **unlocked** (GUI automation requires this)
2. One-time per-VM setup — run `Setup-Vm.ps1` on the VM as admin (see **VM Setup** below)
3. VPN connected to GSS network (`\\gss2k19rnd.gss.local` must be reachable)

```powershell
cd C:\Users\kcao\Projects\cobol-to-c#\Cobol2c.Runner

# Supply the TA01 password via environment (never commit this)
$env:Runner__Ta01Pw = '<your-password-here>'

# Drop a job file into fixtures/jobs/
# (edit Machine to match your assigned VM, Tcs to a TC in tc-manifest.json)
@{
    Id = 'smoke-1'; Suite = 'Cobol2C'; Machine = 'TGFTA-118'; Tcs = @(27510); Logging = $true
} | ConvertTo-Json | Set-Content fixtures\jobs\smoke-1.json

dotnet run --project src\Cobol2c.Runner
#   The runner pushes TA execution to TGFTA-118 via schtasks /s + SMB,
#   polls TAShare for completion, then writes:
#     out/smoke-1.json        (TriageResult from real HTML + CoreLog)
#     out/smoke-1-report.md   (bug report)
```

## Project Structure

```
src\Cobol2c.Runner\
  Program.cs            Host builder + DI (mock ↔ real via Runner:UseMocks config)
  Worker.cs             BackgroundService poll loop
  Configuration\        RunnerOptions
  Jobs\                 IJobSource, TestJob — LocalFileJobSource (PoC) | HttpJobSource (stub)
  Ta\                   ITaExecutor, TaRunResult — MockTaExecutor (PoC) | PowerShellTaExecutor (stub)
                        PowerShellHost — runs pwsh scripts, deserializes JSON stdout
  Triage\               ITriageEngine, PowerShellTriageEngine, Models/
  Reporting\            IBugReportGenerator — TemplateBugReportGenerator (PoC) | ClaudeBugReportGenerator (stub)
  Sinks\                IResultSink — LocalJsonResultSink (PoC) | HttpResultSink (stub)
  scripts\
    TaParsing.psm1      Get-TcResults, Get-ComparableFailed  (from regression skill §Step 2-3)
    TaTrace.psm1        Get-FlowSeq, Get-FlowDivergence, Get-CrashSignature  (§Step 4-5)
    TaRouting.psm1      Get-RouteKey, Use-Cobol, Use-Csharp, Add-CobolRoute  (§routing config)
    TaRemote.psm1       Assert-VmReady, Connect-VmShare, Invoke-RemoteTask, Remove-RemoteTask
    Invoke-Triage.ps1   Entry point — emits TriageResult JSON to stdout
    Invoke-TaRun.ps1    Remote-push TA executor — preflight, push via TaRemote.psm1, poll TAShare
    Setup-Vm.ps1        One-time per-VM admin setup (run ON the VM as admin before first use)

tests\
  Cobol2c.Runner.Tests\TriagePipelineTests.cs   xUnit integration tests (runs real PS scripts)
  pester\TaParsing.Tests.ps1                    PS unit tests — pass/fail detection, comparability gate
  pester\TaTrace.Tests.ps1                      PS unit tests — crash extraction, flow divergence
  pester\TaRouting.Tests.ps1                    PS unit tests — route toggle round-trip
  pester\TaRemote.Tests.ps1                     PS unit tests — preflight error paths, schtasks flag assertions
  pester\TaRecovery.Tests.ps1                   PS unit tests — RDP-drop detection, affected-TC selection

fixtures\
  jobs\job-INV010XR.json                        Sample job (TC 27510, TGFTA-57, Cobol2C)
  ta-results\cobol2c\27510 (...).html           Failing HTML (Passed:&nbsp;0)
  ta-results\reference\27510 (...).html         Passing HTML (Passed:&nbsp;1)
  corelogs\cobol2c\CoreLog_20260609.glog        SYS032→MSG100, STRING: INV010XR<-...<-GSSMENU, no EndTask
  corelogs\reference\CoreLog_20260609.glog      Clean flow, EndTask present
```

## Configuration

`appsettings.json` → `Runner` section:

| Key | Default | Notes |
|-----|---------|-------|
| `UseMocks` | `true` | `false` = real mode; `true` = mock TA executor (fixture paths) |
| `FixturesPath` | `../../fixtures` | Relative to working dir when running |
| `JobsPath` | `../../fixtures/jobs` | Where `LocalFileJobSource` watches |
| `OutputPath` | `../../out` | Where `LocalJsonResultSink` writes |
| `ScriptsPath` | `scripts` | Relative to the executable (copied by build) |
| `PowerShellExe` | `pwsh` | `pwsh` = PowerShell 7+; `powershell` = Windows PowerShell 5.1. Auto-falls back if the configured exe is not found. |
| `PollIntervalMs` | `2000` | Empty-queue delay |
| `Ta01Pw` | *(none)* | **Required in real mode** — TA01 local account password on the VM. Supply via `Runner__Ta01Pw` env var; never commit. |

## Go-Live Swap Table

Four interface swaps turn the PoC into the production runner.  
**Zero triage code changes** — the PS scripts and models stay identical.

| Interface | UseMocks=true | UseMocks=false (current real mode) | Fleet/dashboard (future) |
|-----------|--------------|--------------------------------------|--------------------------|
| `IJobSource` | `LocalFileJobSource` | `LocalFileJobSource` | `HttpJobSource` — Launchpad dashboard API (OAuth) |
| `ITaExecutor` | `MockTaExecutor` | `PowerShellTaExecutor` — remote-push via `Invoke-TaRun.ps1` + `TaRemote.psm1` | *(same)* |
| `IBugReportGenerator` | `TemplateBugReportGenerator` | `TemplateBugReportGenerator` | `ClaudeBugReportGenerator` — Claude API |
| `IResultSink` | `LocalJsonResultSink` | `LocalJsonResultSink` | `HttpResultSink` — POST to dashboard |

### VM Setup (one-time, per-VM)

Before a VM can receive remote-push jobs, run `Setup-Vm.ps1` **on that VM as admin**
(RDP to it, open PowerShell as admin, run the script). This configures three things that
cannot be done remotely:

1. `LocalAccountTokenFilterPolicy = 1` — removes workgroup UAC network token filtering so
   `schtasks /create /s <vm>` with a local admin account is not access-denied.
2. `Enable-NetFirewallRule "Remote Scheduled Tasks Management"` — opens TCP 135 + RPC ports
   so `schtasks /s` can reach the Task Scheduler service.
3. `Apps` share → `C:\Apps` with `TA-CMD` subfolder — lets the controller copy the batch via
   `net use \\<vm>\Apps`.

This setup **survives reboots** but is lost on VM reimage/reassignment. The durable fix is to
bake these three steps into the golden VM image. `Setup-Vm.ps1` is the manual fallback.

After running Setup-Vm.ps1, verify from the controller:
```powershell
Test-NetConnection TGFTA-118 -Port 445   # TcpTestSucceeded: True
Test-NetConnection TGFTA-118 -Port 135   # TcpTestSucceeded: True
net use \\TGFTA-118\Apps /user:TGFTA-118\TA01 <password>
schtasks /query /s TGFTA-118 /u TGFTA-118\TA01 /p <password>
```

### Credentials (real/production mode)

Never hardcode. Supply via environment variables:

```
Runner__Ta01Pw       TA01 local account password on the VM (required in real mode)
RUNNER_CLIENT_SECRET Launchpad Job Client secret (future: HttpJobSource OAuth)
CLAUDE_API_KEY       Claude API key (future: ClaudeBugReportGenerator)
```

## Fixtures vs Real Logs

The fixtures are **synthesized** from the documented format in `regression_test_with_ta/SKILL.md`.  
Before going live, validate them against real `\\gss2k19rnd.gss.local\TAShare` logs:

1. Copy a real failing HTML from `TAShare\Cobol2C\Logs\TGFTA-57\` into `fixtures\ta-results\cobol2c\`
2. Copy a matching passing HTML from `TAShare\SP2V6\Logs\TGFTA-121\` into `fixtures\ta-results\reference\`
3. Copy the corresponding `CoreLog*.glog` files into `fixtures\corelogs\{cobol2c,reference}\`
4. Rename to `CoreLog_20260609.glog` (or update the `MockTaExecutor` paths)
5. Re-run `dotnet test` and `Invoke-Pester` — all assertions should still pass

If any assertion fails after swapping in real logs, the fixture format assumption was wrong.  
Fix the regex/parsing in the relevant `.psm1` function before deploying.
