#!/usr/bin/env bash
# watch-rpm.sh [SECONDS] — READ-ONLY. Sample Fan0 RPM + CPU temp every second (so
# no brief peak is missed), refresh the on-screen line every 5s, and track the
# running MAX of each. Writes NOTHING, so the EC's own automatic fan curve stays
# fully in charge — use it to measure the factory maximum fan speed under load.
# Ctrl-C any time for the peak summary; otherwise it auto-stops after SECONDS
# (default 300s = 5 min) as a fallback so it never runs forever.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0"; exit 1; }
[ -e /proc/acpi/call ] || { echo "acpi_call not loaded: sudo modprobe acpi_call"; exit 1; }
SECS="${1:-300}"     # fallback auto-stop (seconds)
PRINT_EVERY=5        # refresh the displayed line every N seconds

CALL=/proc/acpi/call
RDER='\_SB.PCI0.LPC0.EC0.RDER'
rd(){ echo "$RDER $1" > "$CALL" 2>/dev/null; tr -d '\0' < "$CALL"; }
dec(){ local x="${1//[^0-9a-fA-Fx]/}"; [ -z "$x" ] && { echo 0; return; }; printf '%d' "$x" 2>/dev/null || echo 0; }
rpm(){ echo $(( ($(dec "$(rd 0x0A00)")<<8) | $(dec "$(rd 0x0A01)") )); }
cput(){ local v=0 f; for f in /sys/class/hwmon/hwmon*/name; do grep -q k10temp "$f" 2>/dev/null && v=$(cat "$(dirname "$f")/temp1_input"); done; echo $((v/1000)); }

maxr=0; maxt=0; t=0
summary(){ echo; echo "=== peak: Fan0=${maxr} RPM   CPU=${maxt}C  (read-only, EC auto untouched) ==="; exit 0; }
trap summary INT TERM

echo "READ-ONLY monitor (EC stays in automatic). Sampling 1s, refresh ${PRINT_EVERY}s."
echo "Ctrl-C for peak summary; auto-stops after ${SECS}s."
while :; do
  r=$(rpm); c=$(cput)
  [ "$r" -gt "$maxr" ] && maxr=$r
  [ "$c" -gt "$maxt" ] && maxt=$c
  if [ $(( t % PRINT_EVERY )) -eq 0 ]; then
    printf "\r  t=%-4ss  Fan0=%-5s RPM  CPU=%-3sC   | peak %s RPM / %sC   " "$t" "$r" "$c" "$maxr" "$maxt"
  fi
  t=$((t+1)); [ "$SECS" -gt 0 ] && [ "$t" -ge "$SECS" ] && summary
  sleep 1
done
