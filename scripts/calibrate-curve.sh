#!/usr/bin/env bash
# calibrate-curve.sh — sweep 0x0A18 (duty) and 0x0A19 (mode) at idle to build
# steady-state RPM tables. Read+write, but only ever drives the fan through
# its normal operating range (including all-the-way-off, already verified safe).
# Use the printed table to design your own temperature -> speed curve.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0"; exit 1; }
[ -e /proc/acpi/call ] || { echo "acpi_call not loaded: sudo modprobe acpi_call"; exit 1; }

CALL=/proc/acpi/call
RDER='\_SB.PCI0.LPC0.EC0.RDER'
WTER='\_SB.PCI0.LPC0.EC0.WTER'
rd(){ echo "$RDER $1" > "$CALL" 2>/dev/null; tr -d '\0' < "$CALL"; }
wr(){ echo "$WTER $1 $2" > "$CALL" 2>/dev/null; }
dec(){ local x="${1//[^0-9a-fA-Fx]/}"; [ -z "$x" ] && { echo 0; return; }; printf '%d' "$x" 2>/dev/null || echo 0; }
rpm(){ echo $(( ($(dec "$(rd 0x0A00)")<<8) | $(dec "$(rd 0x0A01)") )); }
cputemp(){ local f v; for f in /sys/class/hwmon/hwmon*/temp1_input; do v=$(cat "$f" 2>/dev/null) || continue; echo $((v/1000)); return; done; echo "?"; }

# settle 3s (skip the recommutation transient), then take 5 samples 1s apart
# and report the median — a single-shot read can land mid-transition and show 0.
median5(){
  local a b c d e s
  a=$(rpm); sleep 1; b=$(rpm); sleep 1; c=$(rpm); sleep 1; d=$(rpm); sleep 1; e=$(rpm)
  s=$(printf '%s\n' "$a" "$b" "$c" "$d" "$e" | sort -n | sed -n 3p)
  echo "$s ($a,$b,$c,$d,$e)"
}

echo "== sweep 0x0A18 (duty), 0x0A19 held at 1 — settle+median per step =="
wr 0x0A19 0x01
printf "%-6s %-8s %-6s %s\n" "duty" "median" "CPU_C" "samples"
for v in 0 3 5 8 10 15 20 30 40 60 80 100 130 160 200 255; do
  wr 0x0A18 "$v"
  sleep 3
  read -r med rest <<<"$(median5)"
  printf "%-6s %-8s %-6s %s\n" "$v" "$med" "$(cputemp)" "$rest"
done

echo ""
echo "== sweep 0x0A19 (mode), 0x0A18 held at 0 — settle+median per step =="
wr 0x0A18 0x00
printf "%-6s %-8s %-6s %s\n" "mode" "median" "CPU_C" "samples"
for v in 0 1 10 20 40 60 85 110 140 170 200 230 255; do
  wr 0x0A19 "$v"
  sleep 3
  read -r med rest <<<"$(median5)"
  printf "%-6s %-8s %-6s %s\n" "$v" "$med" "$(cputemp)" "$rest"
done

echo ""
echo "restoring automatic control..."
wr 0x0A19 0x01
wr 0x0A18 0x03
echo "done. ~180s total. Feed this table into your own temp->speed curve."
