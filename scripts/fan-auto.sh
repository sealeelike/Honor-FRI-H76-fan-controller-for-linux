#!/usr/bin/env bash
# fan-auto.sh — hand the fan back to the EC's automatic temperature control.
# Use this to undo fan-stop.sh / fan-hold.sh. (A reboot does the same thing.)
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0"; exit 1; }
[ -e /proc/acpi/call ] || { echo "acpi_call not loaded: sudo modprobe acpi_call"; exit 1; }
CALL=/proc/acpi/call; WTER='\_SB.PCI0.LPC0.EC0.WTER'
wr(){ echo "$WTER $1 $2" > "$CALL"; }
wr 0x0A19 0x01
wr 0x0A18 0x03
echo "fan returned to automatic mode (0x0A19=1, 0x0A18=3)."
