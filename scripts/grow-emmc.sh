#!/usr/bin/env bash
# grow-emmc.sh — expand mmcblk0p3 to fill the eMMC, grow the LVM LV and XFS root
#
# Safe to re-run: each step checks whether it's already at maximum size.
#
# Operations performed (all online, no reboot required):
#   1. growpart /dev/mmcblk0 3        — extend partition to end of disk
#   2. pvresize /dev/mmcblk0p3        — resize LVM PV to fill partition
#   3. lvextend -l +100%FREE LVRoot   — extend logical volume to fill VG
#   4. xfs_growfs /                   — grow XFS filesystem online
#
# Usage:
#   sudo scripts/grow-emmc.sh
#
# Requirements:
#   dnf install -y cloud-utils-growpart   (provides growpart)

set -euo pipefail

DEVICE="/dev/mmcblk0"
PART="${DEVICE}p3"
VG="systemVG"
LV="LVRoot"
LV_PATH="/dev/${VG}/${LV}"

if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root" >&2
    exit 1
fi

# ── check prerequisites ───────────────────────────────────────────────────────

for cmd in growpart pvresize lvextend xfs_growfs; do
    if ! command -v "${cmd}" &>/dev/null; then
        echo "error: '${cmd}' not found." >&2
        [[ "${cmd}" == "growpart" ]] && echo "  Install with: dnf install -y cloud-utils-growpart" >&2
        exit 1
    fi
done

if [[ ! -b "${PART}" ]]; then
    echo "error: ${PART} not found" >&2
    exit 1
fi

if [[ ! -e "${LV_PATH}" ]]; then
    echo "error: LV ${LV_PATH} not found — check VG/LV names with 'lvs'" >&2
    exit 1
fi

# ── 1. Grow partition ─────────────────────────────────────────────────────────

echo "Step 1: growing partition ${PART} to end of ${DEVICE}..."
GROWPART_OUT=$(growpart "${DEVICE}" 3 2>&1) && GROWPART_RC=0 || GROWPART_RC=$?

if [[ ${GROWPART_RC} -eq 0 ]]; then
    echo "  partition grown"
elif echo "${GROWPART_OUT}" | grep -qi "NOCHANGE"; then
    echo "  partition already at maximum size — skipping"
else
    echo "  growpart failed: ${GROWPART_OUT}" >&2
    exit 1
fi

# ── 2. Resize PV ──────────────────────────────────────────────────────────────

echo "Step 2: resizing LVM PV on ${PART}..."
pvresize "${PART}"
echo "  PV resized"

# ── 3. Extend LV ──────────────────────────────────────────────────────────────

echo "Step 3: extending LV ${LV_PATH}..."
FREE_PE=$(vgdisplay "${VG}" --units b 2>/dev/null | awk '/Free.*PE/{print $5}')
if [[ "${FREE_PE:-0}" -eq 0 ]]; then
    echo "  no free extents in VG — LV already at maximum size"
else
    lvextend -l +100%FREE "${LV_PATH}"
    echo "  LV extended"
fi

# ── 4. Grow XFS filesystem ────────────────────────────────────────────────────

echo "Step 4: growing XFS filesystem on /..."
xfs_growfs /
echo "  XFS filesystem grown"

# ── Summary ───────────────────────────────────────────────────────────────────

echo
echo "Done. Current disk usage:"
df -h / | tail -1
echo
lsblk "${DEVICE}"
