#!/usr/bin/env bash
# fan-hold.sh — keep the fan stopped with a temperature-safe re-assert loop.
# Because the EC auto-curve keeps trying to spin the fan back up, we re-assert
# zero-RPM every second WHILE the CPU is below a threshold. If the CPU gets hot,
# we release the fan back to automatic control so the machine cools normally.
#
# This is a DEMO of the intended behaviour, not an install. Run it in a terminal;
# Ctrl-C releases the fan back to auto. See README for making it a systemd service.
#
#   THRESHOLD_C : below this the fan is held stopped; at/above it, auto control.
#   Registers (HONOR FRI-H76): 0x0A19 enable, 0x0A18 duty. EC RAM volatile => reboot resets.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0"; exit 1; }
[ -e /proc/acpi/call ] || { echo "acpi_call not loaded: sudo modprobe acpi_call"; exit 1; }

THRESHOLD_C="${1:-60}"     # hold fan off below this CPU temp (°C)
CALL=/proc/acpi/call
RDER='\_SB.PCI0.LPC0.EC0.RDER'; WTER='\_SB.PCI0.LPC0.EC0.WTER'
rd(){ echo "$RDER $1" > "$CALL" 2>/dev/null; tr -d '\0' < "$CALL"; }
wr(){ echo "$WTER $1 $2" > "$CALL" 2>/dev/null; }
dec(){ local x="${1//[^0-9a-fA-Fx]/}"; [ -z "$x" ] && { echo 0; return; }; printf '%d' "$x" 2>/dev/null || echo 0; }
rpm(){ echo $(( ($(dec "$(rd 0x0A00)")<<8) | $(dec "$(rd 0x0A01)") )); }
cput(){ local v=0 f; for f in /sys/class/hwmon/hwmon*/name; do grep -q k10temp "$f" 2>/dev/null && v=$(cat "$(dirname "$f")/temp1_input"); done; echo $((v/1000)); }

release(){ wr 0x0A19 0x01; wr 0x0A18 0x03; echo; echo "released fan -> automatic mode."; exit 0; }
trap release INT TERM

echo "holding fan OFF while CPU < ${THRESHOLD_C}C. Ctrl-C to release."
while :; do
  t=$(cput)
  if [ "$t" -lt "$THRESHOLD_C" ]; then
    wr 0x0A19 0x00; wr 0x0A18 0x00
    printf "\r  CPU=%sC  Fan0=%-5s RPM  [holding OFF]     " "$t" "$(rpm)"
  else
    wr 0x0A19 0x01; wr 0x0A18 0x03
    printf "\r  CPU=%sC  Fan0=%-5s RPM  [auto — too warm] " "$t" "$(rpm)"
  fi
  sleep 1
done
