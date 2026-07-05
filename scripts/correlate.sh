#!/usr/bin/env bash
# correlate.sh — READ-ONLY correlation scan used to FIND the fan registers.
# Samples the EC fan block at idle -> heavy CPU load -> cooldown, and reads the
# real hwmon temps each phase. Registers that track RPM (and are NOT a temperature)
# are the fan control/readback registers. Writes NOTHING. Runs ~3.5 min.
#
# On the HONOR FRI-H76 this is how 0x0A00/01 (RPM), 0x0A04 (RPM/100),
# 0x0A08/0A0A/0A0B (readback) were identified. Re-run it to reconfirm on your unit
# or to adapt to a different HONOR model.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0"; exit 1; }
[ -e /proc/acpi/call ] || { echo "acpi_call not loaded: sudo modprobe acpi_call"; exit 1; }
OUT="${1:-/tmp/honor_fan_correlate.txt}"; : > "$OUT"

CALL=/proc/acpi/call
RDER='\_SB.PCI0.LPC0.EC0.RDER'
rd(){ echo "$RDER $1" > "$CALL" 2>/dev/null; tr -d '\0' < "$CALL"; }
dec(){ local x="${1//[^0-9a-fA-Fx]/}"; [ -z "$x" ] && { echo 0; return; }; printf '%d' "$x" 2>/dev/null || echo 0; }
rpm(){ echo $(( ($(dec "$(rd 0x0A00)")<<8) | $(dec "$(rd 0x0A01)") )); }
temps(){ local o="" f v n; for f in /sys/class/hwmon/hwmon*/temp*_input; do [ -f "$f" ]||continue
  v=$(cat "$f" 2>/dev/null); [ -z "$v" ]&&continue; n=$(cat "$(dirname "$f")/name" 2>/dev/null)
  o+=" ${n}:$((v/1000))C"; done; echo "$o"; }
OFFS=(); for n in $(seq 0 31); do OFFS+=("$(printf '0x0A%02X' "$n")"); done
snap(){ local -n a="$1"; a=(); local o; for o in "${OFFS[@]}"; do a+=("$(dec "$(rd "$o")")"); done; }
log(){ echo "$@" >> "$OUT"; }

log "=== EC fan correlation ($(date '+%F %T')) — READ ONLY ==="
log "-- idle 25s --"; sleep 25
log "   Fan0=$(rpm) RPM  hwmon:$(temps)"; declare -a I; snap I
log "-- load ~90s (sha256sum /dev/zero x ncpu) --"
NC=$(nproc); P=(); for i in $(seq 1 "$NC"); do ( exec sha256sum /dev/zero ) & P+=($!); done
for t in 20 40 60 80 90; do sleep $(( t==20?20:(t==90?10:20) )); log "   t+${t}s Fan0=$(rpm) RPM hwmon:$(temps)"; done
declare -a L; snap L; for p in "${P[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null
log "-- cooldown 75s --"; for t in 25 50 75; do sleep 25; log "   t+${t}s Fan0=$(rpm) RPM hwmon:$(temps)"; done
declare -a C; snap C

log ""; log "offset    idle load cool swing  note"
i=0; for o in "${OFFS[@]}"; do a=${I[$i]:-0}; b=${L[$i]:-0}; c=${C[$i]:-0}
  sw=$(( b>a?b-a:a-b )); [ $((c>b?c-b:b-c)) -gt "$sw" ] && sw=$((c>b?c-b:b-c))
  note=""; [ "$a" = "$b" ]&&[ "$b" = "$c" ]&&note="flat"; [ "$sw" -ge 5 ]&&note="tracks-load"
  printf "%-8s  %4s %4s %4s  %4s  %s\n" "$o" "$a" "$b" "$c" "$sw" "$note" >> "$OUT"; i=$((i+1)); done
log "=== done — nothing written. Compare 'tracks-load' regs against hwmon temps. ==="
echo "wrote $OUT"
