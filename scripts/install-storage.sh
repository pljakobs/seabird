#!/usr/bin/env bash
# install-storage.sh — partition and mount NVMe for seabird boat router
#
# NVMe (nvme0n1, 1TB) — entirely btrfs, subvolume-based:
#
#   Subvolume         Mount point                      Purpose
#   @journal          /var/log/journal                 systemd-journald
#   @containers-vol   /var/lib/containers/volumes      podman volume data
#   @data-signalk     /srv/seabird/signalk             Signal-K data
#   @data-influxdb    /srv/seabird/influxdb            InfluxDB data
#   @data-grafana     /srv/seabird/grafana             Grafana data
#   @data-nextcloud   /srv/seabird/nextcloud           Nextcloud data
#   @backup           /srv/seabird/backup              local backups / staging
#   @snapshots        (not mounted — snapper target)   btrfs snapshots
#
# eMMC — unchanged, existing OS layout:
#   /boot/efi   FAT      RPi firmware + UEFI
#   /boot       ext4     kernel + initrd
#   LVM root    xfs      OS, /var/lib/containers (images), slow-changing data
#
# Mount options: noatime,compress=zstd:1,space_cache=v2
#
# Safe to re-run: skips format if btrfs already present, skips subvolume
# creation if it exists, skips fstab entries if already present.
#
# WARNING: first run will FORMAT nvme0n1. Ensure backup is complete.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE="${1:-/dev/nvme0n1}"
MOUNT_OPTS="noatime,compress=zstd:1,space_cache=v2"
LABEL="seabird-data"
TMPDIR_MOUNT="/mnt/seabird-setup"

# ── subvolume definitions: (name, mountpoint) ────────────────────────────────

declare -A SUBVOLS=(
    [@journal]="/var/log/journal"
    [@containers-storage]="/var/lib/containers"
    [@containers-vol]="/var/lib/containers/volumes"
    [@data-signalk]="/srv/seabird/signalk"
    [@data-influxdb]="/srv/seabird/influxdb"
    [@data-grafana]="/srv/seabird/grafana"
    [@data-nextcloud]="/srv/seabird/nextcloud"
    [@backup]="/srv/seabird/backup"
    [@snapshots]=""    # not mounted; used by snapper
)

# ── guards ────────────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root" >&2
    exit 1
fi

if [[ ! -b "${DEVICE}" ]]; then
    echo "error: ${DEVICE} not found or not a block device" >&2
    exit 1
fi

# ── format (skip if already btrfs) ───────────────────────────────────────────

CURRENT_FS=$(blkid -o value -s TYPE "${DEVICE}" 2>/dev/null || true)

# Also refuse to proceed if the device has a partition table — we expect
# btrfs directly on the raw device, not on a partition.
if lsblk -nlo TYPE "${DEVICE}" 2>/dev/null | grep -q "^part$" || \
   lsblk -nlo CHILDREN "${DEVICE}" 2>/dev/null | grep -q "^${DEVICE}p"; then
    echo "error: ${DEVICE} appears to have partitions." >&2
    echo "       This script expects btrfs directly on the raw device." >&2
    echo "       If you want to reformat, wipe the partition table first:" >&2
    echo "         wipefs -a ${DEVICE}" >&2
    exit 1
fi

if [[ "${CURRENT_FS}" == "btrfs" ]]; then
    echo "${DEVICE} is already btrfs — skipping format"
else
    echo "Formatting ${DEVICE} as btrfs (label: ${LABEL})..."
    echo "This will DESTROY all data on ${DEVICE}."
    read -r -p "Type YES to confirm: " confirm
    [[ "${confirm}" == "YES" ]] || { echo "Aborted."; exit 1; }

    mkfs.btrfs -L "${LABEL}" -f "${DEVICE}"
fi

# ── create subvolumes ─────────────────────────────────────────────────────────

mkdir -p "${TMPDIR_MOUNT}"
mount -o "${MOUNT_OPTS}" "${DEVICE}" "${TMPDIR_MOUNT}"

echo "Creating subvolumes..."
for sv in "${!SUBVOLS[@]}"; do
    if [[ ! -d "${TMPDIR_MOUNT}/${sv}" ]]; then
        btrfs subvolume create "${TMPDIR_MOUNT}/${sv}"
        echo "  created ${sv}"
    else
        echo "  ${sv} already exists — skipping"
    fi
done

umount "${TMPDIR_MOUNT}"

# ── create mount points ───────────────────────────────────────────────────────

echo "Creating mount points..."
for sv in "${!SUBVOLS[@]}"; do
    mp="${SUBVOLS[$sv]}"
    [[ -z "${mp}" ]] && continue
    mkdir -p "${mp}"
    echo "  ${mp}"
done

# ── install systemd mount units ───────────────────────────────────────────────

echo "Installing systemd mount units..."
UNIT_SRC="${SCRIPT_DIR}/../config/systemd"

for unit in \
    seabird-mounts.target \
    var-log-journal.mount \
    var-lib-containers.mount \
    var-lib-containers-volumes.mount \
    srv-seabird-signalk.mount \
    srv-seabird-influxdb.mount \
    srv-seabird-grafana.mount \
    srv-seabird-nextcloud.mount \
    srv-seabird-backup.mount; do
    install -m 0644 "${UNIT_SRC}/${unit}" "/etc/systemd/system/${unit}"
    echo "  /etc/systemd/system/${unit}"
done

# Remove old seabird-nvme fstab entries if present from a previous install
if grep -q "seabird-nvme" /etc/fstab 2>/dev/null; then
    echo "Removing legacy seabird-nvme fstab entries..."
    sed -i "/seabird-nvme/d" /etc/fstab
fi

systemctl daemon-reload
systemctl enable --now seabird-mounts.target

# Verify
echo ""
echo "Mounted btrfs subvolumes:"
findmnt -t btrfs --output TARGET,SOURCE,OPTIONS

# ── configure journald to persist to NVMe ────────────────────────────────────

echo ""
echo "Configuring journald to use NVMe..."
chown root:systemd-journal /var/log/journal
chmod 2755 /var/log/journal

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/90-seabird-nvme.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=10G
SystemKeepFree=50G
MaxFileSec=1month
EOF

systemctl restart systemd-journald
echo "journald configured."

echo ""
echo "Storage setup complete."
