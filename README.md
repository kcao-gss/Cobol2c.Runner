# Cobol2c.Runner — Windows Agent PoC

Automated triage runner for the COBOL→C# conversion pipeline.

**PoC scope:** test → triage → bug-report only (no auto-fix, no auto-commit).  
**Stack:** .NET 8 Worker Service (orchestration) + PowerShell (TA mechanics, reused from skills verbatim).

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8) | 8.x | Runtime only is NOT enough — you need the SDK to build |
| [PowerShell 7+](https://github.com/PowerShell/PowerShell/releases) | 7.4+ | `pwsh` must be on PATH |
| [Pester](https://pester.dev/docs/introduction/installation) | 5.x | For PS unit tests only |

Install SDK: `winget install Microsoft.DotNet.SDK.8`  
Install Pester: `Install-Module Pester -Force -SkipPublisherCheck`

## Quick Start (PoC — fully local, no network needed)

```powershell
cd C:\Users\kcao\Projects\cobol-to-c#\Cobol2c.Runner

# 1. Build
dotnet build

# 2. Run all xUnit tests (invokes Invoke-Triage.ps1 against fixtures)
dotnet test

# 3. Run Pester PS unit tests
Invoke-Pester tests\pester -Output Detailed

# 4. Run the worker end-to-end (drains fixtures/jobs/, writes to out/)
dotnet run --project src\Cobol2c.Runner
#   Watch the console — it picks up job-INV010XR.json, runs triage, writes:
#     out/job-INV010XR.json        (TriageResult)
#     out/job-INV010XR-report.md   (bug report)
#   The job file moves to fixtures/jobs/done/ when complete.

# Reset for another run (job file was moved to done/)
Copy-Item fixtures\jobs\done\job-INV010XR.json fixtures\jobs\
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
    Invoke-Triage.ps1   Entry point — emits TriageResult JSON to stdout
    Invoke-TaRun.ps1    Real TA execution stub (implement from run-ta-tests SKILL.md)

tests\
  Cobol2c.Runner.Tests\TriagePipelineTests.cs   xUnit integration tests (runs real PS scripts)
  pester\TaParsing.Tests.ps1                    PS unit tests — pass/fail detection, comparability gate
  pester\TaTrace.Tests.ps1                      PS unit tests — crash extraction, flow divergence
  pester\TaRouting.Tests.ps1                    PS unit tests — route toggle round-trip

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
| `UseMocks` | `true` | `false` = production mode (all stubs must be implemented) |
| `FixturesPath` | `../../fixtures` | Relative to working dir when running |
| `JobsPath` | `../../fixtures/jobs` | Where `LocalFileJobSource` watches |
| `OutputPath` | `../../out` | Where `LocalJsonResultSink` writes |
| `ScriptsPath` | `scripts` | Relative to the executable (copied by build) |
| `PollIntervalMs` | `2000` | Empty-queue delay |

## Go-Live Swap Table

Four interface swaps turn the PoC into the production runner.  
**Zero triage code changes** — the PS scripts and models stay identical.

| Interface | PoC (UseMocks=true) | Production (UseMocks=false) |
|-----------|--------------------|-----------------------------|
| `IJobSource` | `LocalFileJobSource` | `HttpJobSource` — polls Launchpad dashboard API (Launchpad Job Client OAuth) |
| `ITaExecutor` | `MockTaExecutor` | `PowerShellTaExecutor` — runs `Invoke-TaRun.ps1` (port from run-ta-tests SKILL.md) |
| `IBugReportGenerator` | `TemplateBugReportGenerator` | `ClaudeBugReportGenerator` — calls Claude API |
| `IResultSink` | `LocalJsonResultSink` | `HttpResultSink` — POSTs to dashboard API |

### Credentials (production only)

Never hardcode. Supply via environment variables (Launchpad secrets manager in production):

```
TA_GSSTESTER_PW      Password for GSSTester (used by PowerShellTaExecutor / Invoke-TaRun.ps1)
TA_TA01_PW           Password for TA01 (scheduled task run-as account)
RUNNER_CLIENT_SECRET Launchpad Job Client secret for HttpJobSource OAuth
CLAUDE_API_KEY       Claude API key for ClaudeBugReportGenerator
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
