# Cobol2c.Runner — Operations & Current State

_Last updated: 2026-06-25. Snapshot of the headless TA test pipeline, the VM fleet, deployed builds, and open items. Pushed to origin (`github.com/kcao-gss/Cobol2c.Runner`); `master` = `ba7bf3e`._

## What this is
A push-pipeline that runs TestArchitect (TA) GUI tests on remote VMs headlessly and harvests results, for A/B testing the **Cobol2C** (converted C#) suite against the **SP2V6** (COBOL baseline) suite.

- **Controller** (this laptop) → VM over SMB + `schtasks` (RPC). Results return via TAShare marker files + result HTML.
- **Suites:** `Cobol2C` = converted C#; `SP2V6` = COBOL reference; both are the *same* TA tests run against different binaries/keywords.
- **TAShare:** `\\gss2k19rnd.gss.local\TAShare\<suite>\` — `Bin` (base binaries), `<VM>Bin` (per-VM override, overlaid AFTER base so it wins), `Logs\<VM>\` (result HTML + `CoreLogs\*.glog`).

## How to run
- **Single/ad-hoc:** `pwsh -File scripts/Run-Unattended.ps1 -ConfigPath <cfg.json> -Ta01Pw <pw> -OutputDir <dir> < /dev/null` — config = `{suite, logging, vms[], tcs[]}` (template: `scripts/unattended-vms.json`). Runs each VM through Cobol2C + SP2V6, harvests a per-TC matrix. **Always run pwsh with stdin closed (`< /dev/null`).**
- **TC manifest:** `scripts/tc-manifest.json` maps TC → `{rep, prj, path}`. Resolve new TCs with `ta_generate_execute_bat` (TestArchitect MCP) / `Update-TcManifest.ps1`.
- **Deploy a fix to test it:** build the converted DLL, copy it to `\\gss2k19rnd.gss.local\TAShare\Cobol2C\<VM>Bin\`; the run's bat overlays it over base Bin. (Building GSSLegacy: see `[[project-gsslegacy-build-recipe]]` — .NET 4.6.1 Dev Pack + DevExpress 23.2 + 3 DevExpress DLLs copied to the GSSLegacy project root; `dotnet build`.)

## Key pipeline mechanics (hard-won)
- **`Invoke-Cmd` (TaRemote.psm1)** isolates `net use`/`schtasks` in a `Start-Job` with stdin closed (`< NUL`) + a 30s timeout. Without this, a credential dialog from `net use`/`schtasks` hangs the run forever (modal dialog ignores console stdin). Pester covers it (113/0).
- **Per-suite poll cap (Invoke-TaRun.ps1)** scales with batch size: `hardDeadline = max(90, TCs*12)` min — so large batches don't false-timeout.
- **Per-VM output dir (Run-Unattended.ps1)** is GUID-suffixed so concurrent VM runs don't collide.
- **Headless rendering:** VMs autologon as TA01 (LSA-secret, see below) → `console-park.ps1` (`tscon … /dest:console`) parks the session so the GUI renders with no RDP.

## VM fleet — current state (2026-06-25)
| VM | Autologon | State | Notes |
|----|-----------|-------|-------|
| TGFTA-97 | LSA-secret ✅ | idle, healthy | hardened (other session); TMPOR-fixed DLLs deployed |
| TGFTA-98 | LSA-secret ✅ | idle, **flaky** | recovery-thrashed + one GSSMenu crash; **re-provision before trusting its results** |
| TGFTA-99 | LSA-secret ✅ | idle, healthy | clean test VM; TMPOR fix proven here |
- All 3 migrated reg-add-plaintext → **LSA-secret autologon** (no plaintext `DefaultPassword`); verified post-reboot. See `[[project-credential-hardening]]`.

## Deployed builds
- **TMPOR fix** (`FileControlBlock.cs` `.TrimEnd('\0',' ')`) is deployed to base `Cobol2C\Bin\SemanticDesigns.dll` + the `<VM>Bin` overlays. Source committed on **GSSLegacy branch `cobol2c-tmpor-fix` `3bf7f39`** (not pushed; promote to official build).

## Branches & commits (all pushed to origin except GSSLegacy)
- **Cobol2c.Runner / master `ba7bf3e`:** headless pipeline + cred-harden phase 1 + **pre-batch VM reboot & 3-machine unanimous confirmation** (feat, ff `10dc800`) + **Phase-2 pull-agent (Cobol2c.Agent) with `JobExecutor`** (merged `--no-ff`). Builds clean; Agent 23/23, Runner 10/10, Pester 111/111.
- **Cobol2c.Runner / `feat/pre-batch-reboot-3machine-confirmation` `10dc800`:** merged into master; pushed.
- **Cobol2c.Runner / `wip/pull-agent` `3017213`:** `JobExecutor` implemented (BUILDS, 23/23); merged into master; pushed.
- **GSSLegacy / `cobol2c-tmpor-fix` `3bf7f39`:** the TMPOR converted-code fix — still local-only (promote to official build, item 1).

## Open / deferred items
1. **Push & promote** the TMPOR fix to the official GSSLegacy build (it's local-only).
2. **Escalate (TA admin @172.16.43.66):** the residual OE_Shipment NOT-FINISHEDs are **TA-side window/interface verification**, not converted code (the C# screens render; ORD098 control flow verified faithful to COBOL). See report `Projects/cobol2c/reports/OE_Shipment Cobol2C — fix and findings 2026-06-24.md`.
3. **Re-provision TGFTA-98** + pull the GSSMenu crash dump (`C:\Users\TA01\AppData\Local\CrashDumps`).
4. ~~Finish `JobExecutor` on `wip/pull-agent`~~ — **DONE** (merged into `master` `ba7bf3e`, 23/23).
5. **Cred-harden tail:** scrub old plaintext `.bat` on VM 98/99 (Phase-2 pull-agent supersedes); rotate the TA01 password (deferred — still live in history/logs).
6. ~~Working-tree leftovers~~ — **RESOLVED**: applied the session TC additions to `scripts/tc-manifest.json` (6→41 entries), removed the unreferenced `fixtures/jobs/job-INV010XR.json` stray pending-job and the 0-byte `scripts/dispatching` stray; `Update-TcManifest.ps1` was already on master via the merge.

## Credentials (no secrets in this repo)
- VM account: **TA01** (LSA-secret autologon; `-Ta01Pw` passed at runtime, not stored). App-level ERP login: **GSSTester** (in TA test data). The literal TA01 password was removed from the repo in cred-harden phase 1 — do not re-add it.
