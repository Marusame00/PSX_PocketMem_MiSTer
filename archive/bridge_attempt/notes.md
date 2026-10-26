# Bridge Attempt — archived failed project

This folder archives the **PocketBridge attempt**: an attempt to run the full PocketStation
core (ARM7 machine) *beside* the PSX core in a single MiSTer bitstream, so FF8's Chocobo
World send/receive could happen live with the machine running on-chip.

**Result: measured-infeasible on the Cyclone V.** Documented in full below and in
[docs/bridge_attempt.md](../docs/bridge_attempt.md).

## What's in this folder

| File | What it is |
|---|---|
| `PSX_PocketBridge_bridge_attempt.rbf` | A surviving bridge-era build (last decisive experiment: real SPU/MDEC, fixed savestates stub, no machine — the bridge's core state) |
| `notes.md` (this file) | The failed-project notes |

## What was attempted

Vendor the PocketStation machine (~11.15K ALMs) from
[PocketStation_MiSTer](https://github.com/MiSTer-devel/PocketStation_MiSTer) into the PSX
core, with an OSD control-swap between the two sides, so FF8 and Chocobo World could run
side by side and transact card data live.

## Why it failed (measured)

The machine only fits if boot-critical modules are **stubbed** (SPU/MDEC/savestates ~11K) —
and the savestates module is **irreplaceable for boot** (it owns the CPU boot-reset
sequencing: `reset_out` -> `reset_intern`, released via its WAITPAUSE/WAITIDLE FSM +
`SS_idle` handshake). Every stub variant (including corrected reset conditioning and the
`hps_busy` deadlock fix) produced a black screen; only the real modules boot (verified:
real-SPU/MDEC/savestates build boots FF8 clean).

Controlled evidence table (same OSD strip + blackout fix):

| Build | SPU/MDEC | Savestates | Machine | Result |
|---|---|---|---|---|
| Bisect | real | real | no | **BOOTS FF8** |
| C1 | stub | stub | no | BLACK |
| Control | stub | stub fixed | no | BLACK |
| Decisive | real | stub fixed | no | BLACK |
| Full bridge | stub | stub fixed | yes | BLACK |

- Timing was not the discriminator (the booting build ran at -1.085 ns, worse than several
  black builds).
- The machine was exonerated (a no-machine build with the same stubs also blacked).

## The one-line conclusion

**Machine-in (~11K) == stubs-out == no boot.** The two requirements are mutually exclusive
on the 41.9K-device Cyclone V. The bridge idea is falsified at the logic-budget level;
full details, numbers and the AUTO-FIT timing work are in
[docs/bridge_attempt.md](../docs/bridge_attempt.md).

## What survived

The PocketStation **memory-card** emulation (this repo's actual feature) — card protocol,
FF8 detection, save-image interop. That's the basis of `PSX_PocketMem_MiSTer` today.
A physical PocketStation over SNAC on the Superdock does the live transfer that the
bridge couldn't.

## AI disclosure

The bridge attempt was developed with substantial AI assistance (architecture, stub
analysis, controlled builds, evidence interpretation); all hardware testing by the submitter.
