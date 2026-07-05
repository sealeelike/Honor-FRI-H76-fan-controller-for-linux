#!/usr/bin/env bash
# fan-curve.sh — multi-step custom temperature->speed fan curve for the HONOR FRI-H76.
#
# Control model (all measured on this unit, constant-temperature bench):
#   0x0A19 = mode/enable : 0 => hard OFF (0 RPM), 1 => enabled (obeys duty)
#   0x0A18 = speed/duty  : usable range 0..10 ONLY, monotonic & stable:
#       0->0(stops) 1->1763 2->1989 3->2216 5->~2796 8->~3477 10->~3970(max)
#   0x0A18 >= ~16 is UNSTABLE (stall/restart sawtooth) -> NEVER command it.
# The EC servos its own targets back, so a pinned level is re-asserted every second.
# Off / duty levels are re-asserted; the top "AUTO" level hands the EC full control
# (factory curve, may exceed our 3970 cap) and is written once, not re-hammered.
#
# This is a DEMO you run in a terminal (Ctrl-C releases the fan to automatic).
# Registers live in volatile EC RAM: a reboot restores everything. Never write
# 0x0A70-0x0A8F (battery serial). Use at your own risk.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0"; exit 1; }
[ -e /proc/acpi/call ] || { echo "acpi_call not loaded: sudo modprobe acpi_call"; exit 1; }

# ---- curve: "MAXTEMP:DUTY" steps, ascending. DUTY -1 = hand back to EC auto. ----
# Pick the FIRST step whose MAXTEMP is greater than the current temperature.
# duty 10 == the measured factory maximum (~3970 RPM; EC auto peaks ~3993 @100C),
# so the top step forces full speed directly rather than deferring to the EC.
# 0->0  1->1763  2->1989  3->2216  5->~2796  8->~3477  10->~3970(max)   Tjmax=100C.
CURVE=( "65:0" "72:1" "78:2" "84:3" "90:5" "95:8" "999:10" )
HYST_C=3     # must cool this many C below a step boundary before stepping down

CALL=/proc/acpi/call
RDER='\_SB.PCI0.LPC0.EC0.RDER'; WTER='\_SB.PCI0.LPC0.EC0.WTER'
rd(){ echo "$RDER $1" > "$CALL" 2>/dev/null; tr -d '\0' < "$CALL"; }
wr(){ echo "$WTER $1 $2" > "$CALL" 2>/dev/null; }
dec(){ local x="${1//[^0-9a-fA-Fx]/}"; [ -z "$x" ] && { echo 0; return; }; printf '%d' "$x" 2>/dev/null || echo 0; }
rpm(){ echo $(( ($(dec "$(rd 0x0A00)")<<8) | $(dec "$(rd 0x0A01)") )); }
# fail CLOSED: if the k10temp sensor can't be read, report a temp above every
# curve step so the loop hands back to auto instead of silently holding a low duty blind.
cput(){ local f v
  for f in /sys/class/hwmon/hwmon*/name; do
    if grep -q k10temp "$f" 2>/dev/null; then
      v=$(cat "$(dirname "$f")/temp1_input" 2>/dev/null) && [ -n "$v" ] && { echo $((v/1000)); return; }
    fi
  done
  echo 999
}

# pick a curve index for temp t, applying downward hysteresis relative to cur idx
pick(){ local t="$1" cur="$2" i max duty target="$((${#CURVE[@]}-1))"
  for i in "${!CURVE[@]}"; do max="${CURVE[$i]%%:*}"
    if [ "$t" -lt "$max" ]; then target="$i"; break; fi
  done
  # hysteresis: only step DOWN if we've dropped HYST below the lower step's ceiling
  if [ "$target" -lt "$cur" ]; then
    local downmax="${CURVE[$target]%%:*}"
    [ "$t" -ge "$((downmax - HYST_C))" ] && target="$cur"
  fi
  echo "$target"
}

apply(){ local duty="$1"
  if [ "$duty" -lt 0 ]; then wr 0x0A19 0x01; wr 0x0A18 0x03   # hand back to EC auto
  elif [ "$duty" -eq 0 ]; then wr 0x0A19 0x00; wr 0x0A18 0x00 # hard off
  else wr 0x0A19 0x01; wr 0x0A18 "$duty"; fi                  # enabled + duty
}

release(){ wr 0x0A19 0x01; wr 0x0A18 0x03; echo; echo "released fan -> automatic mode."; exit 0; }
trap release INT TERM

echo "custom fan curve running. Ctrl-C to release to auto."
echo "curve (maxC:duty): ${CURVE[*]}   hysteresis=${HYST_C}C"
idx=-1
while :; do
  t=$(cput)
  new=$(pick "$t" "${idx/#-1/0}")
  duty="${CURVE[$new]##*:}"; ceil="${CURVE[$new]%%:*}"
  if [ "$new" != "$idx" ]; then idx="$new"; apply "$duty"        # level changed: apply
  elif [ "$duty" -ge 0 ]; then apply "$duty"; fi                 # same level: re-assert (skip for AUTO)
  lbl="duty=$duty"; [ "$duty" -lt 0 ] && lbl="EC-auto"; [ "$duty" -eq 0 ] && lbl="OFF"
  printf "\r  CPU=%-3sC  Fan0=%-5s RPM  [<%s: %s]        " "$t" "$(rpm)" "$ceil" "$lbl"
  sleep 1
done
