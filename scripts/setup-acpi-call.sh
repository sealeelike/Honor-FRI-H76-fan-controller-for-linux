#!/usr/bin/env bash
# setup-acpi-call.sh — install the acpi_call kernel module (needed to talk to the EC),
# and, if Secure Boot is ON, sign it with a MOK key and enroll that key.
#
# Debian/Ubuntu. Run with sudo. After it finishes:
#   * If it enrolled a key, REBOOT and choose "Enroll MOK" on the blue screen,
#     entering the one-time password you set. Then rerun this script (or just
#     `sudo modprobe acpi_call`).
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0"; exit 1; }

echo "[*] installing acpi-call-dkms + headers ..."
apt-get update -y
apt-get install -y acpi-call-dkms "linux-headers-$(uname -r)" sbsigntool mokutil zstd || true

KREL=$(uname -r)
if modprobe acpi_call 2>/dev/null && [ -e /proc/acpi/call ]; then
  echo "[✓] acpi_call loaded, /proc/acpi/call ready."
  exit 0
fi

# Secure Boot? then the module must be signed with an enrolled MOK key.
SB=$(mokutil --sb-state 2>/dev/null || echo "unknown")
echo "[*] $SB"
if echo "$SB" | grep -qi enabled; then
  MOKDIR=/var/lib/shim-signed/mok
  mkdir -p "$MOKDIR"
  if [ ! -f "$MOKDIR/MOK.der" ]; then
    echo "[*] generating a MOK key pair ..."
    openssl req -new -x509 -newkey rsa:2048 -keyout "$MOKDIR/MOK.priv" \
      -outform DER -out "$MOKDIR/MOK.der" -days 36500 -nodes \
      -subj "/CN=Local module signing key/"
  fi
  KO_ZST=$(find /lib/modules/"$KREL" -name 'acpi_call.ko.zst' 2>/dev/null | head -1)
  KO=$(find /lib/modules/"$KREL" -name 'acpi_call.ko' 2>/dev/null | head -1)
  SIGN=/usr/src/linux-headers-"$KREL"/scripts/sign-file
  if [ -n "$KO_ZST" ]; then zstd -f -d "$KO_ZST" -o "${KO_ZST%.zst}" >/dev/null 2>&1; KO="${KO_ZST%.zst}"; fi
  echo "[*] signing $KO ..."
  "$SIGN" sha256 "$MOKDIR/MOK.priv" "$MOKDIR/MOK.der" "$KO"
  if [ -n "$KO_ZST" ]; then zstd -f -q "$KO" -o "$KO_ZST" && rm -f "$KO"; depmod -a; fi
  echo "[*] enrolling key — you'll set a ONE-TIME PASSWORD now (retype it after reboot):"
  mokutil --import "$MOKDIR/MOK.der"
  echo
  echo ">>> REBOOT, choose 'Enroll MOK' -> Continue -> Yes -> enter that password."
  echo ">>> Then: sudo modprobe acpi_call && ls /proc/acpi/call"
else
  echo "[*] Secure Boot off but module still won't load — check: dkms status"
fi
