#!/usr/bin/env bash
# read-ec.sh — READ-ONLY. Print fan RPM and the key EC fan registers.
# Safe: reads only, writes nothing. Requires root + acpi_call loaded.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0"; exit 1; }
[ -e /proc/acpi/call ] || { echo "acpi_call not loaded: sudo modprobe acpi_call"; exit 1; }

CALL=/proc/acpi/call
RDER='\_SB.PCI0.LPC0.EC0.RDER'
rd(){ echo "$RDER $1" > "$CALL"; tr -d '\0' < "$CALL"; }
dec(){ local x="${1//[^0-9a-fA-Fx]/}"; [ -z "$x" ] && { echo 0; return; }; printf '%d' "$x" 2>/dev/null || echo 0; }

hi=$(dec "$(rd 0x0A00)"); lo=$(dec "$(rd 0x0A01)")
echo "Fan0 RPM        = $(( (hi<<8) | lo ))   (0x0A00=$hi 0x0A01=$lo)"
echo "0x0A04 (RPM/100)= $(dec "$(rd 0x0A04)")"
echo "0x0A18 (duty)   = $(dec "$(rd 0x0A18)")"
echo "0x0A19 (enable) = $(dec "$(rd 0x0A19)")"
echo "0x0A08 (readbk) = $(dec "$(rd 0x0A08)")"
