#!/usr/bin/env bash
# stress-peak.sh [SECONDS] [ABORT_C] — measure the FACTORY maximum fan speed.
# Loads every CPU thread with sha256sum /dev/zero (no packages to install, same
# method as correlate.sh), while READ-ONLY sampling Fan0 RPM + CPU temp. The EC's
# own automatic curve stays fully in charge (we never write the EC), so the peak
# RPM seen here is the vendor's real ceiling under full load.
#
# The LOAD is what gets the time limit: it auto-stops after SECONDS (default 300)
# so the CPU can never cook if you walk away, and the load is ALWAYS killed on
# exit (Ctrl-C, timeout, or the ABORT_C thermal guard). Ctrl-C any time; the peak
# is printed on the way out.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0"; exit 1; }
[ -e /proc/acpi/call ] || { echo "acpi_call not loaded: sudo modprobe acpi_call"; exit 1; }
SECS="${1:-300}"     # load auto-stop (seconds) — the safety fallback
# Thermal abort is OFF by default (0). Tjmax is 95C: the CPU THROTTLES itself to
# sit at ~95C under load — that is normal and safe, and the fan needs ~1min at
# that temp to spool up. Aborting at 95 kills the test before the fan responds.
# Pass a value (e.g. 99) only if you want an extra backstop above the throttle.
ABORT_C="${2:-0}"    # 0 = disabled
PRINT_EVERY=5

CALL=/proc/acpi/call
RDER='\_SB.PCI0.LPC0.EC0.RDER'
rd(){ echo "$RDER $1" > "$CALL" 2>/dev/null; tr -d '\0' < "$CALL"; }
dec(){ local x="${1//[^0-9a-fA-Fx]/}"; [ -z "$x" ] && { echo 0; return; }; printf '%d' "$x" 2>/dev/null || echo 0; }
rpm(){ echo $(( ($(dec "$(rd 0x0A00)")<<8) | $(dec "$(rd 0x0A01)") )); }
cput(){ local v=0 f; for f in /sys/class/hwmon/hwmon*/name; do grep -q k10temp "$f" 2>/dev/null && v=$(cat "$(dirname "$f")/temp1_input"); done; echo $((v/1000)); }

maxr=0; maxt=0; t=0; PIDS=()
finish(){ kill "${PIDS[@]}" 2>/dev/null; wait 2>/dev/null
  echo; echo "=== peak: Fan0=${maxr} RPM   CPU=${maxt}C   (factory auto, EC untouched) ==="; exit 0; }
trap finish INT TERM

NC=$(nproc)
echo "loading all ${NC} threads (sha256sum /dev/zero); READ-ONLY on the EC."
ab="off"; [ "$ABORT_C" -gt 0 ] && ab="${ABORT_C}C"
echo "load auto-stops after ${SECS}s; thermal abort ${ab}; Ctrl-C for peak."
echo "note: 95C is Tjmax — the CPU throttles to sit there safely while the fan ramps."
for i in $(seq 1 "$NC"); do ( exec sha256sum /dev/zero ) & PIDS+=($!); done

while :; do
  r=$(rpm); c=$(cput)
  [ "$r" -gt "$maxr" ] && maxr=$r
  [ "$c" -gt "$maxt" ] && maxt=$c
  [ $(( t % PRINT_EVERY )) -eq 0 ] && \
    printf "\r  t=%-4ss  Fan0=%-5s RPM  CPU=%-3sC   | peak %s RPM / %sC   " "$t" "$r" "$c" "$maxr" "$maxt"
  [ "$ABORT_C" -gt 0 ] && [ "$c" -ge "$ABORT_C" ] && { echo; echo "  CPU ${c}C >= ${ABORT_C}C — stopping early."; finish; }
  t=$((t+1)); [ "$t" -ge "$SECS" ] && { echo; echo "  reached ${SECS}s limit."; finish; }
  sleep 1
done
