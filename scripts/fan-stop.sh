#!/usr/bin/env bash
# fan-stop.sh — force the fan to STOP (zero-RPM) ONCE.
# The EC auto-curve servos the registers back over time, so a single write only
# stops the fan briefly. For a sustained stop use fan-hold.sh (a re-assert loop).
#
# Registers (HONOR FRI-H76): 0x0A19 = enable/mode, 0x0A18 = duty. Both 0 => stop.
# Safe & reversible: EC RAM is volatile; a reboot restores everything.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0"; exit 1; }
[ -e /proc/acpi/call ] || { echo "acpi_call not loaded: sudo modprobe acpi_call"; exit 1; }
CALL=/proc/acpi/call; WTER='\_SB.PCI0.LPC0.EC0.WTER'
wr(){ echo "$WTER $1 $2" > "$CALL"; }
wr 0x0A19 0x00
wr 0x0A18 0x00
echo "fan stop requested (0x0A19=0, 0x0A18=0). Use fan-hold.sh to keep it stopped."
