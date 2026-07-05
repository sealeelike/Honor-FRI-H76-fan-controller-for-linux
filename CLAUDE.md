# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Bash scripts (no build system, no tests, no dependencies to compile) that control the fan on a
**HONOR MagicBook X 14 Pro Ryzen 2023 (model FRI-H76)** running Linux, by writing the Embedded
Controller (EC) directly. The machine exposes no `hwmon`/`pwm`/`thermal` fan interface and the
Insyde BIOS has no fan option, so EC pokes are the only lever. The headline capability is holding
the fan at a true **zero-RPM** stop while the CPU is cool.

Read `README.md` (user-facing), `RESEARCH_NOTES.md` (how the registers were reverse-engineered),
and `WORK_IN_PROGRESS.md` (current unfinished task — see below) before making changes.

## How the control path works

- All EC access goes through two DSDT ACPI methods under `\_SB.PCI0.LPC0.EC0`:
  - `RDER <offset16>` → read one byte of extended EC space (`0x0Axx`).
  - `WTER <offset16> <value>` → write one byte.
  - The generic `ec_sys` module **cannot** reach these `0x0Axx` offsets — that is why RDER/WTER exist.
- These methods are invoked from userspace by echoing to `/proc/acpi/call`, provided by the
  **`acpi_call`** kernel module. Every script uses the same idiom:
  `echo '\_SB.PCI0.LPC0.EC0.RDER 0x0A00' > /proc/acpi/call; tr -d '\0' < /proc/acpi/call`.
- The EC runs its own temperature→fan servo in firmware (a black box) that **slowly reasserts its
  own register values**. A one-shot write only takes effect for a few seconds; sustained control
  requires re-writing the target every ~1 s (the "hold" loop pattern).

## The registers (measured on FRI-H76 — do not assume they transfer to other models)

| Offset | Meaning |
|---|---|
| `0x0A00` / `0x0A01` | Fan0 RPM readback hi/lo → `RPM = (0x0A00<<8) \| 0x0A01` |
| `0x0A04` | RPM ÷ 100 readback |
| `0x0A18` | fan duty / speed target (write high → faster) |
| `0x0A19` | fan enable / mode |
| `0x0A08`,`0x0A0A`,`0x0A0B` | state readback only — writes get overwritten by the EC |

- **Stop:** `WTER 0x0A19 0` then `WTER 0x0A18 0`. **Auto:** `WTER 0x0A19 1` then `WTER 0x0A18 3` (or reboot).

## Hard safety rules (non-negotiable)

- **Never write `0x0A70`–`0x0A8F`.** On this machine that region holds the battery vendor/serial
  ASCII strings, not fan data. Corrupting it is not reversible by reboot.
- Any deployment loop **must** keep the temperature threshold that hands the fan back to automatic
  control when the CPU gets hot. Do not ship a loop that can hold the fan off unconditionally.
- EC RAM is volatile: a reboot restores everything, and nothing here touches BIOS/firmware flash.
  This is what makes write-experiments recoverable — but only within the fan registers above.
- When adding a *new* register experiment, drive the fan **faster** first (safe at idle); only try
  to slow/stop after you have confirmed the register's meaning.

## Working conventions in this repo

- **Claude does not run the EC scripts.** They require `sudo` on the real hardware and are run by
  the user in their own terminal. Write/modify a script, hand it to the user, wait for the real
  output, then analyze. Do not invent register semantics from guesswork — every claim here came
  from a measured correlation scan.
- Read-only scripts (`read-ec.sh`, `correlate.sh`, `probe-value.sh`) are the safe way to
  investigate; prefer extending those over adding new writes.
- All scripts share the same header boilerplate: `set -uo pipefail`, a root check, an
  `/proc/acpi/call` existence check, and the `rd`/`wr`/`dec`/`rpm` helper functions. Match it.
- `.gitignore` excludes `*.txt`/`*.log`/`*.tmp` — scan output files (e.g. `correlate.sh`'s
  `/tmp/honor_fan_correlate.txt`) are intentionally not committed.

## Script map

| Script | Reads/Writes EC | Purpose |
|---|---|---|
| `scripts/setup-acpi-call.sh` | neither | install `acpi-call-dkms`; under Secure Boot, sign the module with a MOK key and enroll it (requires a reboot + "Enroll MOK") |
| `scripts/read-ec.sh` | read | print current RPM and key registers |
| `scripts/correlate.sh` | read | idle→load→cooldown scan of the whole fan block to *find* the registers (adapts to other models) |
| `scripts/probe-value.sh REG VALUE [SECS]` | read+write | hold one (register,value) fixed, print per-second RPM to distinguish steady state from oscillation |
| `scripts/calibrate-curve.sh` | read+write | sweep `0x0A18` and `0x0A19` to build a value→RPM table (see WIP caveat) |
| `scripts/fan-stop.sh` / `fan-auto.sh` | write | one-shot stop / return-to-auto |
| `scripts/fan-hold.sh [THRESHOLD_C]` | read+write | temperature-safe re-assert loop holding zero-RPM below the threshold; the deployable behaviour |
| `systemd/honor-fan.service` + `systemd/honor-fan-hold` | write | boot-time service wrapping `fan-hold.sh`; `ExecStopPost` returns the fan to auto |

## Current in-progress task (as of WORK_IN_PROGRESS.md)

Designing a full temperature→speed **custom curve** (not the factory curve, which lives in the EC
firmware black box and is unreadable). `calibrate-curve.sh` produced an anomalous "alternating
zero" pattern; the leading hypothesis is aliasing between the sampling cadence and the motor's own
stall/restart cycle. `probe-value.sh` was written to check this with long single-value time series
but **its output has not been collected yet** — the next step is to get those runs from the user
before trusting any calibration table or extending `fan-hold.sh` into a multi-step curve daemon.
