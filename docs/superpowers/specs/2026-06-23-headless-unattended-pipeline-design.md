# Headless Unattended Test Pipeline — Design Spec

- **Date:** 2026-06-23
- **Status:** Approved (design); pending implementation plan
- **Author:** Kyler (with Claude Code)
- **Component:** `Cobol2c.Runner` (the push-pipeline: controller → VM via `schtasks`, results via TAShare)

## 1. Background

The `Invoke-TaRun.ps1` pipeline drives TestArchitect (TA) GUI tests on remote TGFTA VMs from a
controller. TA's GUI automation requires an **interactive desktop that is actively rendering**.
Until now the only way to get that was `Connect-TA01Rdp` — launch `mstsc` on the controller and RDP
into the VM. That has two fatal properties for unattended operation:

1. **It needs an interactive controller.** `mstsc` must draw into a desktop on the controller; if
   the controller is locked/logged-off, nothing renders and tests blank-abort.
2. **It needs a human** to clear the RDP publisher prompt and to keep the window non-minimized (a
   minimized RDP session stops rendering → `Cannot maximize window` → Not-Finished).

A full investigation (2026-06-23) established that the SP2V6 "all-failing" results were **not** the
pipeline, build, or tests — they were this rendering problem (minimized RDP + un-rebooted VMs).
Once a VM is rebooted and its desktop renders, the expected tests pass (Inventory/Purchasing/
Manufacturing/Sales all green; only the intrinsic QS cases + 27537 genuinely fail).

**Key proven result:** TA tests render and pass with **zero RDP viewer** by parking TA01's session
onto the console via `tscon <session-id> /dest:console` (run as SYSTEM on the VM). Verified on
TGFTA-99: 27510 PASSED with nobody connected. This removes the interactive-controller dependency and
makes fully-headless / overnight runs possible.

## 2. Goal & Non-Goals

**Goal:** Kick off a TA suite run (SP2V6 or any suite) that completes **overnight with zero human
interaction** — no RDP clicks, no foreground windows — triggered from this laptop (`GSS-LT-0166`),
which stays powered on (logged-off is fine).

**Non-goals (YAGNI):**
- The full **pull-agent** (agent running inside the VM). Separate, larger effort; this spec reuses
  the existing push-pipeline.
- **Dynamic VM claiming.** VMs come from a fixed config list (below).
- **RDP cert-trust.** Not needed — `tscon` console-park replaces RDP entirely for headless runs.
  `Connect-TA01Rdp` remains only as an attended-mode fallback.

## 3. Architecture

The pipeline already runs tests correctly once a session renders. This design changes the **session
bootstrap** and adds a **trigger** and **per-run provisioning** — it is not a rewrite.

### A. Console-park session bootstrap (replaces Connect-TA01Rdp in headless mode)
New function `Enter-ConsoleSession -Machine -Ta01Pw` (in `TaRecovery.psm1`, beside `Connect-TA01Rdp`):
1. Deploy a small `console-park.ps1` to the VM (`C:\Windows\Temp\` via `C$`).
2. Create + run a **SYSTEM** scheduled task on the VM that runs it.
3. `console-park.ps1` (runs on the VM as SYSTEM): parse `qwinsta` for TA01's session id, run
   `tscon <id> /dest:console`, log result to `C:\Windows\Temp\park.log`.
4. Controller reads `park.log` to confirm `exit=0`.

This renders TA01's desktop on the console with no viewer. Idempotent (safe to re-run).

### B. No-lock provisioning
New function `Set-VmNoLock -Machine -Ta01Pw`: on the VM set
`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\InactivityTimeoutSecs=0`, disable the
screensaver, and ensure no lock-on-idle, so the console session keeps rendering through a multi-hour
run. Applied per run.

### C. Self-provision per run
For each VM in the config list, at run start the pipeline applies (idempotent):
existing `Setup-Vm` essentials (LocalAccountTokenFilterPolicy, Remote Scheduled Tasks firewall rule,
Apps share / TA-CMD folder) + `Set-VmNoLock` + `Enter-ConsoleSession`.

### D. Recovery re-park
The existing wedge-recovery (`Invoke-VMRecovery`: reboot) must, after the VM returns, call
`Enter-ConsoleSession` (a reboot resets the session, so it must be re-parked) instead of / in
addition to `Connect-TA01Rdp`, when in headless mode.

### E. Overnight trigger
New `Install-OvernightTrigger.ps1`: registers a **SYSTEM** scheduled task on `GSS-LT-0166` that runs
`Run-Unattended.ps1` at a configured time. SYSTEM tasks run logged-off; the laptop must stay powered.

### F. New entry point: `Run-Unattended.ps1`
Reads the VM config, loops VMs (isolated per-VM — one VM's failure doesn't abort the others),
self-provisions each (C), runs the configured suite via the existing `Invoke-SuiteRun` with
`-Headless` mode, harvests results (mapped-drive + `^<tc>[_ ]` matcher), writes a per-run summary
JSON + a human-readable matrix.

## 4. Configuration

`unattended-vms.json` (or `.txt`) — the fixed set of VMs assigned to the user, plus the suite and TC
set. Example:
```json
{ "suite": "SP2V6", "logging": true, "tcs": ["27510","27514", "..."], "vms": ["TGFTA-99","TGFTA-98"] }
```

## 5. Mode flag

Thread a `-Headless` (or `-Unattended`) switch through `Invoke-TaRun.ps1` → `Invoke-SuiteRun` →
recovery. When set: use `Enter-ConsoleSession` for the session bootstrap and re-park after reboot.
When unset (default / attended): preserve current `Connect-TA01Rdp` behavior. This keeps the attended
path unchanged and makes headless opt-in.

## 6. Error handling

- **Per-VM isolation:** `Run-Unattended.ps1` wraps each VM in try/catch; a failure logs and continues
  to the next VM.
- **Ownership sanity-check:** before claiming a configured VM, check for another user's active
  `ta execute` (the `ta-knguyen` lesson) via `tasklist`/`Win32_Process` CommandLine; skip + log if busy.
- **Console-park verification:** if `park.log` does not show `exit=0` / a console session, log and
  treat the VM as not-ready (skip its run rather than produce false Not-Finished).
- **Recovery cap:** keep the existing 2-recovery cap; re-park counts as part of recovery.

## 7. Testing

- **Pester unit tests** (match existing `tests/pester` style):
  - `Enter-ConsoleSession` session-id parse: given sample `qwinsta` output (incl. a Disc session with
    blank SESSIONNAME), extract the correct numeric id.
  - `Set-VmNoLock` builds the correct registry commands.
  - `-Headless` flag routes the bootstrap to `Enter-ConsoleSession` (mock) not `Connect-TA01Rdp`.
- **E2E:** the headless probe already run (console-park + 27510, no RDP → PASS), extended to the full
  configured suite on the fixed VMs.

## 8. Risks / Open items

- **Powered-on controller required.** A closed laptop is off → nothing runs. The overnight trigger
  assumes `GSS-LT-0166` stays powered (lid-open or "do nothing on lid close", plugged in).
- **Pool reassignment.** The fixed VM list can be reassigned out from under the user; the
  ownership sanity-check mitigates collisions but a reassigned VM will simply be skipped+logged.
- **`tscon` durability.** Proven once; confirm it survives a full multi-hour multi-TC run (the
  extended E2E covers this). If the console session still drifts, `Set-VmNoLock` is the backstop.

## 9. Files (new / modified) in `Cobol2c.Runner`

- New: `src/Cobol2c.Runner/scripts/console-park.ps1` (VM-side, deployed at run time)
- Modified: `src/Cobol2c.Runner/scripts/TaRecovery.psm1` (+`Enter-ConsoleSession`, recovery re-park)
- New: `src/Cobol2c.Runner/scripts/Set-VmNoLock.ps1` (or a function in an existing module)
- Modified: `src/Cobol2c.Runner/scripts/Invoke-TaRun.ps1` (+`-Headless` flag, thread through `Invoke-SuiteRun`)
- New: `src/Cobol2c.Runner/scripts/Run-Unattended.ps1` (entry point)
- New: `src/Cobol2c.Runner/scripts/Install-OvernightTrigger.ps1` (controller SYSTEM task)
- New: `unattended-vms.json` (config)
- New: `tests/pester/TaHeadless.Tests.ps1`
