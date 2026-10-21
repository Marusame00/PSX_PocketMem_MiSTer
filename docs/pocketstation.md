# PocketStation support (PSX_MiSTer)

Status: **v1.** RTL + GHDL simulation; built with Quartus Prime Lite and smoke-tested on hardware (FF8 / Chocobo World). See "Hardware test results" and "Known limitations" below.

## What it does

Memory Card 1 and Memory Card 2 each have an OSD option:

| OSD entry | status bit | Default |
|---|---|---|
| Memory Card 1 Type: Standard / PocketStation | `status[65]` | Standard |
| Memory Card 2 Type: Standard / PocketStation | `status[58]` | Standard |

When a slot is set to **PocketStation**, the slot answers the PocketStation BU command set in addition to the standard Sony card commands. The 128 KB image format is unchanged.

Standard mode is the default. With the option off, the card behaves as before (81h/52h/57h, original frame, checksum, 47h end).

Bits 58 and 65 were free in the OSD string and in every `status[]` reference in `PSX.sv`. Re-check them if another feature takes them.

## Command support

Source of truth: no$psx "Pocketstation BU command summary" (`psx-spx.htm`, anchor `pocketstationbucommandsummary`).

| Command | Behaviour |
|---|---|
| 53h Get ID | 5A 5D 5C 5D 04 00 00 80 (same as Sony cards) |
| 58h | 02h, 01h, 01h |
| 50h | length 00h |
| 59h Prepare Execute | length 06h; dir_index hi/lo (0000h..000Fh accepted, FFFFh read-only); four param bytes |
| 5Ah Status | 12h, then 18 bytes: dir_index, ComFlags 0/1/3/2, F_SN (zeros), BCD date/time, day of week |
| 5Bh / 5Ch | FUNC echoed as FFh, LEN1, params, LEN2, data, FFh |
| 5Dh Download notify | length 03h; value bytes 16–23, 8–15, 0–7. Bits 8–15 = 00h sets ComFlags.10 (write-protect) |
| 5Eh | ComFlags bits 1, 3, 2 (new value in, old value out) |
| 5Fh | ComFlags bit 0 (new value in, old value out) |
| 52h / 57h | Standard read/write, but 00h dummies instead of echoed bytes |

### Write behaviour (PocketStation mode)

- Data is written into the sector buffer as it arrives. The DDR3 commit happens **only** after the host checksum matches **and** the sector is writable.
- Write-protect: while ComFlags.10 is set, sectors 16–55 are rejected with **FEh**.
- Bad checksum: **4Eh**, no commit.
- Good write: **47h**.
- Standard mode is unchanged: commit at the end of the data phase.

### FUNC support (5Bh/5Ch)

| FUNC | Status |
|---|---|
| 00h date/time | Served from the MiSTer RTC (`RTC_host`, 8 bytes) |
| 01h memory read/write | Lengths per spec (LEN1 5, LEN2 = 5th param clipped to 80h). **Data is zero; writes ignored** |
| 02h alarm/flags | Lengths per spec. **Data is zero** |
| 03h custom | Lengths per spec. **Data is zero** |
| 80h+ flash function table | Accepted, **no data** |

## RTL changes (ports and registers)

### `rtl/joypad_mem.vhd`

New ports (both default to the standard-card behaviour when left unconnected):

- `isPocketStation : in std_logic := '0'`
- `rtc_in : in std_logic_vector(64 downto 0) := (others => '0')` (MSM6242B-style BCD: `[7:0]` sec, `[15:8]` min, `[23:16]` hour, `[31:24]` day, `[39:32]` month, `[47:40]` year (20xx), `[50:48]` DOW 0=Sunday)

The DOW layout matches `PocketStation_MiSTer/PocketStation.sv` (`host_rtc[50:48] + 1`).

### `rtl/joypad.vhd`

- New ports: `isPocketStation1`, `isPocketStation2` (default '0'), `rtc_in` (default zero).
- Passed to the two `joypad_mem` instances.

### `rtl/psx_top.vhd`, `rtl/psx_mister.vhd`

- Same three ports, passed through to `joypad`.

### `PSX.sv`

- `hps_io` `.RTC(RTC_host)` connected (previously only `.TIMESTAMP` was connected).
- `isPocketStation1 = status[65]`, `isPocketStation2 = status[58]`.
- OSD entries `O[65]` and `O[58]` added after `SC3,SAVMCD`.

Standard-mode regression is covered by the testbench (Phase A). It is not a netlist-level equivalence check against the previous release.

## Save interop with PocketStation_MiSTer

Both cores use the same raw 128 KB card image. `PocketStation_MiSTer/README.md` states that a `.sav` can be carried between the two cores without conversion.

- PSX_MiSTer automatic save: `saves/PSX/<game>.sav` (from `FileGenerateSavePath` in `Main_MiSTer/file_io.cpp`).
- Slot-mounted card: the `.sav` you mount in the card slot is read in and written back to that same file.
- PocketStation_MiSTer save folder: not verified from its sources. Check the folder name on your SD card before copying.

Hot swap: copy the 128 KB `.sav` between the two cores' save folders while both are powered off or unmounted.

## Simulation

Testbench: `sim/pocketstation/tb_joypad_mem_ps.vhd` with a behavioral `sim/pocketstation/dpram_dif_sim.vhd` (the Altera `dpram` is not usable in GHDL).

```
ghdl -a --std=08 --workdir=WORK sim/pocketstation/dpram_dif_sim.vhd rtl/joypad_mem.vhd sim/pocketstation/tb_joypad_mem_ps.vhd
ghdl -e --std=08 --workdir=WORK tb_joypad_mem_ps
ghdl -r --std=08 --workdir=WORK tb_joypad_mem_ps --stop-time=100ms
```

Last result: 1663 byte exchanges, 0 errors (GHDL 6.0.0, mcode).

Covers: standard regression (57h/52h round trip, 53h/58h/5Bh ignored), PocketStation 53h/58h/50h/59h/5Ah/5Eh/5Fh/5Bh FUNC 00h and 01h, write/read round trip, ComFlags.10 write-protect (sector 20 unchanged, sector 60 writable), bad checksum (sector unchanged).

## Hardware test results (real MiSTer, FF8 US / Chocobo World)

Tested with a build of this branch (Quartus Prime Lite 17.0.0, Cyclone V, PSX.rbf):

- Standard card behaviour unchanged: normal saves/loads worked before and after the new OSD options.
- FF8 (SLUS-00892) with **Memory Card 2 Type = PocketStation** and a Chocobo World file on the card:
  - FF8 detects the PocketStation and offers to send the chicobo; the transfer completes.
  - Byte-level check of the resulting 128 KB image: the CW file's directory entry and executable sectors are unchanged; only its save-data region was modified in place, i.e. FF8 performed real read-modify-write transactions through the PocketStation BU command path (5Ah/59h/5Bh/5Dh and 52h/57h with checksums).
  - The PocketStation core booted the file FF8 wrote; the transferred data was visible on the PocketStation side.
- Not yet working end to end: returning the chicobo to FF8. See limitations below.

## Known limitations / open items

- **No device-state continuity across a core switch.** A real PocketStation stays powered and keeps `dir_index`, ComFlags and kernel state between docking sessions. This implementation resets them when the core reloads, and a FF8 reunion check can fail after switching cores. Making this state persist (e.g. into the savestate region or the card image) is the main open item for full Chocobo World round trips.
- **F_SN (serial number) reads as 0000h.** Device-identification via 5Ah returns zeros.
- FUNC 01h/02h/03h/80h+ data is not emulated. FDh (exec-file directory protection) and FFFEh dir_index are not emulated.
- No minigame execution here by design: that is the PocketStation core's job. This core only presents a card that behaves like a PocketStation at the SIO protocol level.

## Development note

This feature was developed with AI assistance (interactive RTL/simulation pair-programming): protocol analysis against the no$psx BU command documentation, the joypad_mem state machine, the GHDL testbench, and the OSD/wiring changes. All hardware testing and validation was done by the submitter on a real MiSTer.


