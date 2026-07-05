#!/usr/bin/env bash
# fan-hold.sh [ON_C] [HYST_C] — keep the fan stopped with a temperature-safe
# re-assert loop. Because the EC auto-curve keeps trying to spin the fan back
# up, we re-assert zero-RPM every 0.5s WHILE the CPU is cool. Once CPU reaches
# ON_C we hand the fan fully back to the EC's own automatic curve — and, to
# avoid chattering right at that boundary, we do NOT resume holding it off
# again until CPU drops HYST_C below ON_C (e.g. 65 up / 60 down, a dead zone
# in between where whichever state we were already in just continues).
#
# This is a DEMO of the intended behaviour, not an install. Run it in a terminal;
# Ctrl-C releases the fan back to auto. See README for making it a systemd service.
#
#   Registers (HONOR FRI-H76): 0x0A19 enable, 0x0A18 duty. EC RAM volatile => reboot resets.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0"; exit 1; }
[ -e /proc/acpi/call ] || { echo "acpi_call not loaded: sudo modprobe acpi_call"; exit 1; }

ON_C="${1:-65}"       # hand fan to EC auto at/above this CPU temp (°C)
HYST_C="${2:-10}"     # must drop this many °C below ON_C before holding OFF again
OFF_C=$((ON_C - HYST_C))
CALL=/proc/acpi/call
RDER='\_SB.PCI0.LPC0.EC0.RDER'; WTER='\_SB.PCI0.LPC0.EC0.WTER'
rd(){ echo "$RDER $1" > "$CALL" 2>/dev/null; tr -d '\0' < "$CALL"; }
wr(){ echo "$WTER $1 $2" > "$CALL" 2>/dev/null; }
dec(){ local x="${1//[^0-9a-fA-Fx]/}"; [ -z "$x" ] && { echo 0; return; }; printf '%d' "$x" 2>/dev/null || echo 0; }
rpm(){ echo $(( ($(dec "$(rd 0x0A00)")<<8) | $(dec "$(rd 0x0A01)") )); }
# fail CLOSED: if the k10temp sensor can't be read, report a temp above THRESHOLD_C
# so the loop hands back to auto instead of silently holding the fan off blind.
cput(){ local f v
  for f in /sys/class/hwmon/hwmon*/name; do
    if grep -q k10temp "$f" 2>/dev/null; then
      v=$(cat "$(dirname "$f")/temp1_input" 2>/dev/null) && [ -n "$v" ] && { echo $((v/1000)); return; }
    fi
  done
  echo 999   # sensor unreadable -> treat as dangerously hot, force auto
}

release(){ wr 0x0A19 0x01; wr 0x0A18 0x03; echo; echo "released fan -> automatic mode."; exit 0; }
trap release INT TERM

echo "holding fan OFF below ${OFF_C}C, auto at/above ${ON_C}C (${HYST_C}C hysteresis band). Ctrl-C to release."
state=off   # start assuming cool; a real read on the first loop corrects this immediately
while :; do
  t=$(cput)
  [ "$state" = off ] && [ "$t" -ge "$ON_C" ] && state=auto
  [ "$state" = auto ] && [ "$t" -lt "$OFF_C" ] && state=off
  if [ "$state" = off ]; then
    wr 0x0A19 0x00; wr 0x0A18 0x00
    printf "\r  CPU=%-3sC  Fan0=%-5s RPM  [holding OFF, resumes below %sC]  " "$t" "$(rpm)" "$OFF_C"
  else
    wr 0x0A19 0x01; wr 0x0A18 0x03
    printf "\r  CPU=%-3sC  Fan0=%-5s RPM  [auto, until below %sC]          " "$t" "$(rpm)" "$OFF_C"
  fi
  sleep 0.5
done
