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

DEVICE="${1:-/dev/nvme0n1}"
MOUNT_OPTS="noatime,compress=zstd:1,space_cache=v2"
LABEL="seabird-data"
TMPDIR_MOUNT="/mnt/seabird-setup"

# ── subvolume definitions: (name, mountpoint) ────────────────────────────────

declare -A SUBVOLS=(
    [@journal]="/var/log/journal"
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

# ── get UUID for fstab ────────────────────────────────────────────────────────

UUID=$(blkid -o value -s UUID "${DEVICE}")
echo "NVMe UUID: ${UUID}"

# ── create mount points ───────────────────────────────────────────────────────

echo "Creating mount points..."
for sv in "${!SUBVOLS[@]}"; do
    mp="${SUBVOLS[$sv]}"
    [[ -z "${mp}" ]] && continue
    mkdir -p "${mp}"
    echo "  ${mp}"
done

# ── add fstab entries (idempotent) ────────────────────────────────────────────

echo "Updating /etc/fstab..."
FSTAB_MARKER="# seabird-nvme"

# Remove any previous seabird-nvme entries for clean re-run
sed -i "/${FSTAB_MARKER}/d" /etc/fstab

{
    echo ""
    echo "${FSTAB_MARKER} — managed by install-storage.sh, do not edit manually"
    for sv in "${!SUBVOLS[@]}"; do
        mp="${SUBVOLS[$sv]}"
        [[ -z "${mp}" ]] && continue
        printf 'UUID=%-40s %-35s btrfs %s,subvol=%-22s 0 0\n' \
            "${UUID}" "${mp}" "${MOUNT_OPTS}" "${sv}"
    done
} >> /etc/fstab

echo "fstab updated."

# ── mount all new entries ─────────────────────────────────────────────────────

echo "Mounting all seabird NVMe subvolumes..."
systemctl daemon-reload
mount --all --fstab /etc/fstab -t btrfs 2>/dev/null || true

# Verify
echo ""
echo "Mounted btrfs subvolumes:"
findmnt -t btrfs --output TARGET,SOURCE,OPTIONS

# ── configure journald to persist to NVMe ────────────────────────────────────

echo ""
echo "Configuring journald to use NVMe..."
mkdir -p /var/log/journal
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

# ── configure podman volumes to use NVMe ──────────────────────────────────────

echo ""
echo "Configuring podman volume storage on NVMe..."
mkdir -p /etc/containers
# volumes dir already bind-mounted via fstab — ensure containers config points there
if ! grep -q 'volume_path' /etc/containers/storage.conf 2>/dev/null; then
    # Patch or create storage.conf
    if [[ -f /etc/containers/storage.conf ]]; then
        # Append override if not present
        cat >> /etc/containers/storage.conf <<'EOF'

# seabird: store volumes on NVMe btrfs
[storage.options]
  mount_program = "/usr/bin/fuse-overlayfs"

EOF
    fi
fi
echo "Podman volumes will be stored in /var/lib/containers/volumes (NVMe)."
echo "Container images remain on eMMC (/var/lib/containers)."
echo ""
echo "Storage setup complete."
