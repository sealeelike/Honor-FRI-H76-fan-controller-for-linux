#!/usr/bin/env bash
# probe-value.sh REG VALUE [SECONDS] [CEIL_C] — HOLD one (register,value) pair and
# sample RPM every second, so you see the true steady state of that value rather
# than an EC-servo transient. The value is RE-ASSERTED every second (the EC servos
# its own targets back otherwise), and its pairing register is pinned:
#   probing 0x0A19 -> 0x0A18 is held at 0
#   probing 0x0A18 -> 0x0A19 is held at 1
#
# SAFETY: if CPU temp reaches CEIL_C (default 85) the fan is handed straight back
# to automatic control and the script aborts. It also restores auto on exit/Ctrl-C.
#
# Example: sudo bash probe-value.sh 0x0A19 20 30
# Example: sudo bash probe-value.sh 0x0A18 60 30 80   # abort ceiling 80C
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0"; exit 1; }
[ -e /proc/acpi/call ] || { echo "acpi_call not loaded: sudo modprobe acpi_call"; exit 1; }
REG="${1:?usage: $0 0x0A18|0x0A19 VALUE [SECONDS] [CEIL_C]}"
VAL="${2:?usage: $0 0x0A18|0x0A19 VALUE [SECONDS] [CEIL_C]}"
SECS="${3:-30}"
CEIL="${4:-85}"

CALL=/proc/acpi/call
RDER='\_SB.PCI0.LPC0.EC0.RDER'
WTER='\_SB.PCI0.LPC0.EC0.WTER'
rd(){ echo "$RDER $1" > "$CALL" 2>/dev/null; tr -d '\0' < "$CALL"; }
wr(){ echo "$WTER $1 $2" > "$CALL" 2>/dev/null; }
dec(){ local x="${1//[^0-9a-fA-Fx]/}"; [ -z "$x" ] && { echo 0; return; }; printf '%d' "$x" 2>/dev/null || echo 0; }
rpm(){ echo $(( ($(dec "$(rd 0x0A00)")<<8) | $(dec "$(rd 0x0A01)") )); }
cputemp(){ local f v; for f in /sys/class/hwmon/hwmon*/temp1_input; do v=$(cat "$f" 2>/dev/null) || continue; echo $((v/1000)); return; done; echo 0; }

# which register to pin while we drive the other one
case "$REG" in
  0x0A19|0x0a19) PAIR_REG=0x0A18; PAIR_VAL=0x00 ;;
  0x0A18|0x0a18) PAIR_REG=0x0A19; PAIR_VAL=0x01 ;;
  *) echo "REG must be 0x0A18 or 0x0A19"; exit 1 ;;
esac

restore(){ wr 0x0A19 0x01; wr 0x0A18 0x03; echo; echo "restored automatic control (0x0A19=1, 0x0A18=3)."; }
trap 'restore; exit 130' INT TERM

echo "baseline: 0x0A19=1, 0x0A18=3 (auto-ish), settle 5s"
wr 0x0A19 0x01; wr 0x0A18 0x03; sleep 5

echo "HOLDING $REG=$VAL (pin $PAIR_REG=$PAIR_VAL ONCE), re-asserting only $REG for ${SECS}s."
echo "safety: abort to auto if CPU >= ${CEIL}C."
wr "$PAIR_REG" "$PAIR_VAL"          # set the paired register ONCE — re-hammering it
wr "$REG" "$VAL"                    # every second is what causes the sawtooth artifact
for t in $(seq 1 "$SECS"); do
  wr "$REG" "$VAL"                  # re-assert ONLY our target (fight the slow EC servo)
  c=$(cputemp); r=$(rpm)
  printf "t+%02ds  RPM=%-5s CPU=%s\n" "$t" "$r" "$c"
  if [ "$c" -ge "$CEIL" ]; then
    echo ">>> CPU hit ${c}C >= ${CEIL}C — aborting to auto for safety."
    restore; exit 0
  fi
  sleep 1
done

echo "restoring automatic control..."
restore
