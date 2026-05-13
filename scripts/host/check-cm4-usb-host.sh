#!/usr/bin/env bash
set -euo pipefail

echo "Checking host prerequisites for CM4 USB block-device workflow..."

missing=0

for cmd in rpiboot lsusb lsblk mount; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "MISSING: $cmd"
    missing=1
  fi
done

if [[ "$missing" -ne 0 ]]; then
  echo "Install missing tools first (run scripts/host/setup-cm4-usb-host.sh as root)." >&2
  exit 1
fi

echo
echo "USB devices containing Raspberry/Broadcom identifiers:"
lsusb | grep -Ei 'Raspberry|Broadcom|0a5c:2711' || true

echo
echo "Block devices currently visible:"
lsblk -o NAME,SIZE,TYPE,MODEL,TRAN

echo
echo "If CM4 is in USB boot mode and rpiboot has been executed, a new block device should appear above."
