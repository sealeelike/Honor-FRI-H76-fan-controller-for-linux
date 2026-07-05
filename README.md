# HONOR MagicBook fan control on Linux (FRI-H76 / FRI-HXX)

Custom fan control — including **full zero-RPM (fan completely stopped)** — for the
**HONOR MagicBook X 14 Pro 锐龙版 2023** on Linux (Debian / Ubuntu).

- **Product**: 荣耀 MagicBook X 14 Pro 锐龙版 2023, 集显, R7 16GB+512GB
- **Model**: **FRI-H76** (FRI-HXX series, SKU C233)
- **SoC**: AMD Ryzen 7 7840HS + Radeon 780M (integrated)
- **BIOS**: Insyde (locked — no fan option in setup)

On this machine Linux exposes **no** `hwmon`/`pwm`/`thermal` interface for the fan,
there is no fan option in the BIOS, and `nbfc` has no profile for it. The only way
to control the fan is to talk to the **Embedded Controller (EC)** directly. This repo
does exactly that, safely and reversibly.

> **TL;DR** — two EC registers control the fan:
> `0x0A19` = enable/mode, `0x0A18` = speed. Writing both to `0` stops the fan.
> The EC keeps trying to spin it back up, so a 1-second re-assert loop holds it
> stopped while the CPU is cool, and releases it to automatic control when warm.

---

## ⚠️ Read this first

- **Only confirmed on the HONOR FRI-H76.** Other HONOR models likely use the same
  scheme but **different register offsets** — run `scripts/correlate.sh` to find
  yours before writing anything. **Do not blindly reuse these offsets on another model.**
- Writing the EC is **reversible**: EC RAM is volatile, so a **reboot restores
  everything**. This does **not** touch the BIOS/firmware flash.
- **Never write** the region **`0x0A70`–`0x0A8F`** — on this machine it holds the
  **battery vendor / serial strings**, not fan data. The fan registers are all in
  the low `0x0A00`–`0x0A19` range and do not overlap it.
- Holding the fan off raises the idle equilibrium temperature. The provided loop has
  a **temperature threshold** that releases the fan back to automatic control when
  the CPU heats up. Keep it enabled. Use at your own risk.

---

## How it works

The DSDT exposes two EC accessor methods under `\_SB.PCI0.LPC0.EC0`:

- `RDER(offset16)` → read one byte from extended EC space
- `WTER(offset16, value)` → write one byte to extended EC space

(These reach the `0x0Axx` extended offsets; the generic `ec_sys` module cannot.)
We call them from userspace via the **`acpi_call`** kernel module (`/proc/acpi/call`).

### The registers (measured on FRI-H76)

| Offset | Meaning | Evidence |
|---|---|---|
| `0x0A00` / `0x0A01` | Fan0 RPM readback (hi/lo). `RPM = (0x0A00<<8) \| 0x0A01` | reads real RPM |
| `0x0A04` | RPM ÷ 100 readback | 25 ↔ 2500 RPM |
| **`0x0A18`** | **Fan speed / duty target** | writing 10 drove RPM 2513→3636 at constant temp |
| **`0x0A19`** | **Fan enable / mode** | `0`→**stops (0 RPM)**, `1`→~1846, `85`→2331, `170`→2639 |
| `0x0A08`,`0x0A0A`,`0x0A0B` | current-state readback (writes get overwritten) | not control inputs |

**Stop the fan:** `WTER(0x0A19,0)` then `WTER(0x0A18,0)`.
**Back to automatic:** `WTER(0x0A19,1)` then `WTER(0x0A18,3)` (or just reboot).

### Why a loop is needed

The EC runs its own temperature→fan curve in the background and slowly **servos the
registers back** to its own targets. A single write only stops the fan for a few
seconds. Re-asserting `0`/`0` about once per second holds it stopped. That is what
`fan-hold.sh` / the systemd service do — and they hand control back to the EC above a
temperature threshold so the machine always cools when it needs to.

### Verified result

At idle, holding `0x0A19=0 / 0x0A18=0` kept **Fan0 at 0 RPM for 37 of 40 s**, with the
CPU rising only **43 → 45 °C** (Tjmax is 95 °C). Releasing restored automatic control
and the fan spun back up normally.

---

## Install

### 1. Get `acpi_call` working (once)

```bash
sudo bash scripts/setup-acpi-call.sh
```

This installs `acpi-call-dkms`. **If Secure Boot is enabled** it also generates a MOK
signing key, signs the module, and enrolls the key — then you **reboot once**, choose
**Enroll MOK** on the blue screen, and enter the one-time password you set. After that:

```bash
sudo modprobe acpi_call
ls /proc/acpi/call        # should exist
```

### 2. Try it live (no install)

```bash
sudo bash scripts/read-ec.sh          # show fan RPM + registers
sudo bash scripts/fan-stop.sh         # stop the fan once
sudo bash scripts/fan-auto.sh         # give it back to automatic control
sudo bash scripts/fan-hold.sh 60      # hold fan off while CPU < 60°C (Ctrl-C to release)
```

### 3. Optional: run it at boot (systemd)

```bash
sudo install -m 755 scripts/fan-hold.sh /usr/local/bin/honor-fan-hold
sudo install -m 644 systemd/honor-fan.service /etc/systemd/system/honor-fan.service
sudo systemctl daemon-reload
sudo systemctl enable --now honor-fan.service
# edit the "60" in the service file to change the temperature threshold
```

Stop/undo:

```bash
sudo systemctl disable --now honor-fan.service   # ExecStopPost returns fan to auto
```

---

## Scripts

| Script | What it does | Writes EC? |
|---|---|---|
| `scripts/setup-acpi-call.sh` | install + (if needed) sign & enroll `acpi_call` | no |
| `scripts/read-ec.sh` | print fan RPM and key registers | no |
| `scripts/correlate.sh` | idle/load/cooldown scan to **find** the fan registers | no |
| `scripts/fan-stop.sh` | stop the fan once | yes |
| `scripts/fan-auto.sh` | return the fan to automatic control | yes |
| `scripts/fan-hold.sh` | temperature-safe loop that holds the fan stopped | yes |

## Adapting to another HONOR model

Run `sudo bash scripts/correlate.sh` and read the output table. The register whose
value tracks RPM under load (and is *not* one of your `hwmon` temperatures) is your
RPM readback; the enable/duty pair are usually right next to it. Confirm with small,
reversible up-writes (drive the fan *faster* first — that's always safe at idle)
before trying to slow or stop it.

## Keywords

HONOR MagicBook X 14 Pro Ryzen 2023, FRI-H76, FRI-HXX, MagicBook fan control Linux,
Ubuntu Debian custom fan curve, zero RPM silent fan, EC embedded controller acpi_call,
Ryzen 7840HS fan noise, quiet laptop Linux, WTER RDER EC register.

## License

MIT — see [LICENSE](LICENSE).
