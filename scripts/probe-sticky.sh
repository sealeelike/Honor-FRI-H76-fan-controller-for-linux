#!/usr/bin/env bash
# probe-sticky.sh REG VALUE [SECONDS] [CEIL_C] — test whether a candidate value is a
# "sticky" special value the EC firmware leaves alone, as opposed to an ordinary target
# that the EC's own thermal servo periodically overwrites.
#
# Unlike probe-value.sh (which RE-WRITES every second — great for reading a steady-state
# RPM, but it also masks drift: if the EC nudges the register between our write and our
# read, we overwrite it again before ever seeing it stick), this script writes the value
# EXACTLY ONCE and then only READS for the rest of the run. If nothing is fighting us,
# RPM should sit flat at whatever that value produces. If the EC's servo is still active,
# RPM will visibly drift away over time (this is the same servo that made the old
# calibrate-curve.sh sweep look unstable).
#
# SAFETY: this is passive after the single write, so if the value turns out NOT to be
# sticky, the EC simply reclaims control and drives the fan per its own curve — nothing
# is held against rising temperature. As an extra backstop, if CPU reaches CEIL_C the
# script still forces a restore to known-good auto values.
#
# Example: sudo bash probe-sticky.sh 0x0A18 0xFF 120
# Example: sudo bash probe-sticky.sh 0x0A18 0x80 180 90
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0"; exit 1; }
[ -e /proc/acpi/call ] || { echo "acpi_call not loaded: sudo modprobe acpi_call"; exit 1; }
REG="${1:?usage: $0 0x0A18|0x0A19 VALUE [SECONDS] [CEIL_C]}"
VAL="${2:?usage: $0 0x0A18|0x0A19 VALUE [SECONDS] [CEIL_C]}"
SECS="${3:-120}"
CEIL="${4:-85}"

CALL=/proc/acpi/call
RDER='\_SB.PCI0.LPC0.EC0.RDER'
WTER='\_SB.PCI0.LPC0.EC0.WTER'
rd(){ echo "$RDER $1" > "$CALL" 2>/dev/null; tr -d '\0' < "$CALL"; }
wr(){ echo "$WTER $1 $2" > "$CALL" 2>/dev/null; }
dec(){ local x="${1//[^0-9a-fA-Fx]/}"; [ -z "$x" ] && { echo 0; return; }; printf '%d' "$x" 2>/dev/null || echo 0; }
rpm(){ echo $(( ($(dec "$(rd 0x0A00)")<<8) | $(dec "$(rd 0x0A01)") )); }
cputemp(){ local f v; for f in /sys/class/hwmon/hwmon*/temp1_input; do v=$(cat "$f" 2>/dev/null) || continue; echo $((v/1000)); return; done; echo 0; }
readback(){ dec "$(rd "$1")"; }

case "$REG" in
  0x0A19|0x0a19) PAIR_REG=0x0A18; PAIR_VAL=0x00 ;;
  0x0A18|0x0a18) PAIR_REG=0x0A19; PAIR_VAL=0x01 ;;
  *) echo "REG must be 0x0A18 or 0x0A19"; exit 1 ;;
esac

restore(){ wr 0x0A19 0x01; wr 0x0A18 0x03; echo; echo "restored automatic control (0x0A19=1, 0x0A18=3)."; }
trap 'restore; exit 130' INT TERM

echo "baseline: 0x0A19=1, 0x0A18=3 (auto-ish), settle 5s"
wr 0x0A19 0x01; wr 0x0A18 0x03; sleep 5

echo "writing $REG=$VAL ONCE (pin $PAIR_REG=$PAIR_VAL ONCE), then READ-ONLY for ${SECS}s."
echo "watching for drift = EC still servoing; flat RPM + flat readback = looks sticky."
echo "safety: abort to auto if CPU >= ${CEIL}C."
wr "$PAIR_REG" "$PAIR_VAL"
wr "$REG" "$VAL"

for t in $(seq 1 "$SECS"); do
  c=$(cputemp); r=$(rpm); rb=$(readback "$REG")
  printf "t+%03ds  RPM=%-5s CPU=%-3s  readback(%s)=%s\n" "$t" "$r" "$c" "$REG" "$rb"
  if [ "$c" -ge "$CEIL" ]; then
    echo ">>> CPU hit ${c}C >= ${CEIL}C — aborting to auto for safety."
    restore; exit 0
  fi
  sleep 1
done

echo "done. restoring automatic control..."
restore
