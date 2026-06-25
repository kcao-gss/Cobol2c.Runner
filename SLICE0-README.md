# Slice-0: Pull-Agent End-to-End Validation (TA01)

VM validation checklist for the first vertical slice of the Cobol2c pull-agent.
All steps run on TA01 (the test VM with the autologon session).
Orchestrator and agent both run on TA01 in slice-0 (no cross-machine networking).

## Prerequisites

- .NET 8 SDK installed on TA01, or publish self-contained from the controller.
- TA application staged: C:\Cobol2c.Staging has Bin\ and Plugins\ sub-directories.
- TA01 autologon enabled (Session 1, no RDP window).

## Step 1: Publish

Run on the controller (or on TA01 if .NET SDK is present):

```
cd C:\path\to\Cobol2c.Runner
dotnet publish src\Cobol2c.Agent -r win-x64 -p:SelfContained=true -o C:\Cobol2c.Agent.Publish
dotnet publish src\Cobol2c.StubOrchestrator -r win-x64 -p:SelfContained=true -o C:\Cobol2c.Orch.Publish
```

Copy both publish output dirs to TA01.

## Step 2: Register the agent scheduled task (on TA01)

```powershell
C:\Cobol2c.Agent.Publish\Install-AgentTask.ps1 `
    -AgentExe C:\Cobol2c.Agent.Publish\Cobol2c.Agent.exe `
    -OrchestratorUrl http://localhost:5100
```

Verify registration:

```powershell
Get-ScheduledTask -TaskName Cobol2c.Agent
# Expected State: Ready
```

## Step 3: Start the stub orchestrator (on TA01)

Open a terminal on TA01 and run:

```
C:\Cobol2c.Orch.Publish\Cobol2c.StubOrchestrator.exe
```

It binds to http://localhost:5100 and holds one hardcoded job: TC 27510, suite Cobol2C.
It exits after one job is dispatched and the result is received.

## Step 4: Start the agent (on TA01)

```powershell
# Via scheduled task (recommended -- validates the logon-trigger path):
Start-ScheduledTask -TaskName Cobol2c.Agent

# Or run directly from a terminal:
C:\Cobol2c.Agent.Publish\Cobol2c.Agent.exe
```

## Step 5: Observe logs

Orchestrator console (expected):

```
info: Program[0] [orch] GET /jobs/next from TGFTA-LOCAL -> dispatching slice0-job-001
info: Program[0] [orch] Job slice0-job-001 result saved. FailLog=... -> results\slice0-job-001.json
```

Agent console or Event Log (expected):

```
info: Cobol2c.Agent.AgentLoop[0] Got job slice0-job-001 suite=Cobol2C tcs=27510
info: Cobol2c.Agent.AgentLoop[0] Job slice0-job-001 complete. FailLog=...
```

## Step 6: Verify result file

```powershell
Get-Content C:\Cobol2c.Orch.Publish\results\slice0-job-001.json
# Expected: JSON with FailLogDir and RefLogDir fields populated
```

Pass criteria: the file exists and both log dirs are non-empty strings.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Agent: connection refused :5100 | Orchestrator not running | Start orchestrator first |
| Agent: 204 on first poll | Job already dispatched | Restart orchestrator process |
| TC manifest not found | scripts/ not in publish output | Re-publish (csproj copies scripts/** to output) |
| TA batch hangs on started.txt | No Bin/ or Plugins/ at LocalBase | Stage C:\Cobol2c.Staging\Bin and \Plugins for slice-0 |
| Task state: Disabled or not found | Install-AgentTask.ps1 not run | Run Step 2 on TA01 as TA01 user |
