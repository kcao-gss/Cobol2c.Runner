# COBOL2C fix-verify-report loop — design spec

**Date:** 2026-06-24
**Status:** draft for review
**Owner:** Kyler (kcao)
**Related:** `2026-06-23-headless-unattended-pipeline-design.md`; skill `regression_test_with_ta` (Steps 8–10); Obsidian `Projects/cobol2c/reports/`

## Goal
Operationalize the manager's directive: take a **triaged** Cobol2C regression, **hand-patch the converted C# locally to prove the fix**, rebuild, deploy to a VM, **re-test via the pipeline, iterating to green**, then write a **Markdown report + proof diff** that drives the *official* change made by the conversion-owning team.

This is the existing `regression_test_with_ta` Steps 8–10, made into a repeatable, pipeline-backed loop with a defined deliverable. The local C# edit is a **proof-of-fix only** — not the official change.

## Non-goals
- Not committing/PRing the fix to the shared `Cobol2C\Bin` or official repo (the report drives that separately).
- Not fixing the COBOL→C# transpiler here (the report may *recommend* a transpiler-level fix; making it is out of scope).
- Not re-running the full 27/35 matrix (separate, already-parked track — now unblocked by Gate A).

## Prerequisites (gates)
- **Gate A — pipeline launch (DONE 2026-06-24).** `Invoke-Cmd` in `TaRemote.psm1` rewritten to isolate `cmd` in a `Start-Job`, close child stdin (`< NUL`), and apply a 30s timeout. Root cause was a modal Windows credential dialog (`CredUIPromptForWindowsCredentials`) from `net use`/`schtasks` that ignores console stdin and blocked forever. Pester **113/0**; verified end-to-end on TGFTA-99 (bat→`ta.exe`→`started.txt`→9 HTMLs→`finished.txt`).
- **Gate B — local build (DONE 2026-06-24, green: 0 errors, `bin\Debug\GSSLegacy.dll` ~53 MB).** `GSSLegacy.sln` targets **.NET Framework 4.6.1**; build via the dotnet 8 SDK's MSBuild (`dotnet build GSSLegacy.sln -c Debug`), no Visual Studio required. Full recipe (three pieces, not one):
  1. **.NET Framework 4.6.1 Developer Pack** (https://aka.ms/msbuild/developerpacks) — fixes `MSB3644`.
  2. **DevExpress 23.2** installed (licensed; the GSS UI suite — `DateEdit`/`ButtonEdit`/`XtraForm`).
  3. **Copy the 3 referenced DevExpress v23.2 DLLs** (`DevExpress.Data.v23.2.dll`, `DevExpress.Utils.v23.2.dll`, `DevExpress.XtraEditors.v23.2.dll`) from `C:\Program Files\DevExpress 23.2\Components\Bin\Framework\` into the **GSSLegacy project root** — the csproj references them by *bare filename* HintPath, so MSBuild only finds them next to the project (modern DevExpress doesn't GAC).
  - GSS internal refs (`GSSEO.dll`, `SP2Forms.dll`, `Fujitsu.COBOL.dll`, `GSSERP.*.V2.dll`…) resolve from `\\gss2k19rnd\Development\…` UNC (reachable from the controller). (Official build is otherwise CI/Jenkins — `JenkinsBuildToHF/HFSuspend/BuildSteps/02-Build-Projects.ps1`; no local-PC-setup doc exists in MCP-Intelligence.)

## Inputs / environment (all local on the controller laptop)
| Thing | Location |
|---|---|
| Converted C# source | `C:\Users\kcao\Projects\cobol-to-c#\GSSLegacy` (git repo, `GSSLegacy.sln`) |
| COBOL reference source | `C:\LocalCOBOLSearch\trunk\cobol\fujsource\<PGM>.CBL` |
| Build output | `…\GSSLegacy\bin\Debug\GSSLegacy.dll` (+ `SemanticDesigns.dll` if changed) |
| Deploy target (override bin) | `\\gss2k19rnd.gss.local\TAShare\Cobol2C\<machine>Bin` — pipeline overlays this over the base `Bin` next run, shared Bin untouched |
| Routing override (must be ABSENT for our C# proof) | `\\<machine>\TA01\DataCache\CoreModernCodeConfig.unclearedCache` |
| Pipeline | `Cobol2c.Runner` scripts (now Gate-A-fixed) |
| Report destination | Obsidian `Projects/cobol2c/reports/` |

## The loop (per regression)
1. **Edit** the converted C# in GSSLegacy on a local proof branch — target the *root cause* (restore original-COBOL behavior), not a symptom guard at the crash site.
2. **Build:** `dotnet build GSSLegacy.sln -c Debug` (post Gate B). Surface compile errors, stop.
3. **Deploy** only the DLLs whose `LastWriteTime` changed (typically `GSSLegacy.dll`) to `\\…\TAShare\Cobol2C\<machine>Bin`.
4. **Ensure routing runs C#:** delete any stale `CoreModernCodeConfig.unclearedCache` on the executing VM (else we'd test COBOL → false green).
5. **Re-test** the TC via the pipeline (failing machine, Cobol2C suite, with logging).
6. **Read verdict + new trace**, return to step 1.

**Progress gate:** "progress" = each cycle yields new useful information (deeper crash point, narrowed field, new divergence). **10 cycles with no new info → stop and surface** what was tried + current hypothesis; ask whether to continue. Never loop silently.

## First target
**ORD098 / TMPOR "create-before-open"** — the single defect behind all **8** OE_Shipment TCs (one C# fix should flip all eight; already fully root-caused, highest leverage). Converted C# is in `GSS/SupplyChain/Shipping/Base/` — likely `ShipmentOrderSelection.cs` (the OES098S "Choose Selection Criteria" entry; references `TMPOR`); confirm exact file/method in the plan. Root cause (from triage): the C# `Gss.SupplyChain.Shipping.Base` omits the COBOL `OPEN OUTPUT TMPOR-FILE → CLOSE → OPEN I-O TMPOR-FILE` create step (`ORD098.CBL` 1989–1992) → `OPEN I-O` on a non-existent Vision-ISAM file → `Status:90` → screen never renders → NOT-FINISHED. After ORD098, reuse the loop for whatever the 27-run triage surfaces.

## Definition of done (per fix)
1. TC flips **NOT-FINISHED → `Passed ≥ 1`** in the Cobol2C suite.
2. **Green verified to come from the fixed C#** — no stale `unclearedCache` forcing COBOL (false green guard).
3. **Root cause, not symptom** — change corrects the faulty conversion at the right layer (a defect in a shared helper like `SemanticDesigns.*` belongs there, not patched per-program); temporary instrumentation removed.
4. **Impact reviewed** — search the repo for other callers of the changed method/class; re-run a representative set of TCs on the same program/path to confirm no regression; flag any behavior that legitimately changes for other callers.

## Deliverable (report)
Per-fix **Markdown report** in Obsidian `Projects/cobol2c/reports/` (same template family as the 8 triage reports):
- Root cause (and why it's the cause, not a symptom)
- The exact C# **diff** that fixes it (file + change), and why this is the best/safest form
- The original-COBOL behavior it restores (`<PGM>.CBL` line refs)
- Before/after **test evidence** (HTML result paths, verdict flip)
- Impact review (other callers/TCs checked + results)
- **Recommended official change** for the conversion-owning team
The proof-fix is kept on a **local git branch in GSSLegacy** (clean attachable diff) — **not pushed** (report is the deliverable).

## Components & boundaries
- **Editor/fixer** (human + Claude): edits GSSLegacy on a proof branch; owns steps 1–2.
- **Deployer** (script): copies changed DLLs to `<machine>Bin`; clears stale routing override; steps 3–4.
- **Test runner** (pipeline, Gate-A-fixed): runs the TC, returns verdict + trace; step 5.
- **Reporter**: writes the Obsidian report at done.
Each is independently runnable and observable (the deploy and routing-clear are small, idempotent scripts; the pipeline is the existing one).

## Risks
1. **Build env (Gate B)** — mitigated by the 4.6.1 Developer Pack; until installed, no local build. *Verify a clean build before any fix work.*
2. **Per-call 30s timeout** (Gate A fix) could spuriously trip on slow network RPC under 3-VM load; pipeline recovery/retry absorbs it, and a fast error beats an infinite hang. Revisit only if it fires in practice.
3. **False green from stale routing override** — step 4 explicitly clears it every iteration.
4. **net461 build correctness** — we keep the project on net461 (matching production); never retarget to satisfy the toolchain.
5. **Iteration cost** — a TA run is ~8–10 min; instrument generously per cycle to avoid extra round-trips.

## Open items
- Confirm exact ORD098 C# file/method (plan step).
- Reconcile Gate B with the Beacon "core PC setup" doc (full VS vs targeting-pack-only) once Beacon reconnects.
