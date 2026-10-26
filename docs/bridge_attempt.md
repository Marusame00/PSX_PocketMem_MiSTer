---
## Bridge attempt — measured verdict (2026-10-24) — The bridge is measured-infeasible on this device

**The combined PSX + PocketStation-machine bitstream DOES fit and DOES meet timing —
but it does NOT boot.** Extensive controlled builds prove a hard architectural conflict:
the machine only fits if boot-critical modules are stubbed, and stubbing them breaks boot.

### The complete evidence table (all machine-free unless noted; same OSD strip + blackout fix)
| # | Build | SPU/MDEC | Savestates | Machine | ALMs | Timing | Result |
|---|-------|----------|------------|---------|------|--------|--------|
| 1 | Bisect | real     | real       | no      | 97%  | -1.085 | **BOOTS FF8** |
| 2 | C1     | stub     | stub       | no      | 71%  | -0.118 | BLACK |
| 3 | Control| stub     | stub fxd   | no      | 73%  | +0.264 | BLACK |
| 4 | Build  | real     | stub fxd   | no      | 85%  | +0.095 | BLACK |
| 5 | Mach 1 | stub     | stub fxd   | yes     | 98%  | -0.425 | BLACK |
| 6 | Mach 2 | stub fxd| stub fxd   | yes     | 98%  | -0.125 | BLACK |

- **Timing is not the discriminator:** build 1 booted at -1.085 ns (WORSE than every black build).
- **The machine is exonerated:** builds 4 vs 1 — real SPU/MDEC + stub savestates, no machine — still BLACK.
- **The savestates module is the boot-critical, irreplaceable piece.** It owns the CPU boot
  reset sequencing: `reset_out` -> `reset_intern` (psx_top.vhd:2090), released through its
  WAITPAUSE/WAITIDLE FSM and the `SS_idle` handshake. Every stub variant (incl. corrected
  reset conditioning + hps_busy deadlock fix `6901ab3`) blacks; only the real module boots.
- **The architectural contradiction:** the machine needs ~11.15K ALMs; the stubs are what
  freed ~11K. Machine-in == stubs-out == no boot. A ~5-6K cut that keeps savestates real
  (scaler 2.3K, GPU feature strip, MDEC 0.6K) would still gut video and likely fail to fit.

### What DID work on hardware (from PR #391 experience + this core)
- A physical PocketStation over SNAC on the Superdock does the LIVE transfer — the real goal
  works that way.
- `joypad_mem` PocketStation card emulation (this repo's basis): FF8 detects the card,
  downloads data, saves rewrite byte-verified. Kept here as the usable artifact.

### The valuable surviving piece
Use the repo as a **single-territory PocketStation memory-card solution** — the memcard
emulation + save-interop paths, NOT the full bridge. The bridge idea itself (both cores live
in one bitstream) is falsified by the table above.

### Do NOT (unchanged)
- Do NOT push or add a remote to PSX_PocketBridge_MiSTer. Owner creates the repo.
- Do NOT commit tools/, ref/, *.sav, output_files/, db/, *.qsf.

### File map (unchanged)
- `rtl/pocketstation/` = vendored PocketStation machine (ps_asic, bridge_machine.sv wrapper)
- `rtl/stubs/` = hollow spu.vhd / mdec.vhd / savestates.vhd (identical ports, inert)
- `rtl/psx.qip` lines 38/46/52 redirect to stubs; files.qip adds machine + BIOS MIF
- `sim/fit_machine/` = standalone machine-fit measurement project (11,150 ALMs baseline)
