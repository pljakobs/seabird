#!/usr/bin/env bash
# bootstrap.sh — initial bring-up for the seabird boat router
#
# Run this once (as root) after flashing Fedora and cloning the repo:
#
#   git clone <repo-url> /opt/seabird
#   cd /opt/seabird
#   sudo scripts/bootstrap.sh
#
# What it does (all steps are idempotent — safe to re-run):
#   1. Install required host packages via dnf
#   2. Apply pcie-32bit-dma overlay (5G modem DMA fix)
#   3. Set hostname to seabird (skip with --no-hostname)
#   4. Format NVMe and create btrfs subvolumes  →  install-storage.sh
#   5. Deploy firewalld zones, captive portal, Caddy  →  install-firewall.sh
#   6. Deploy service quadlets  →  install-services.sh
#   7. Enable podman auto-update timer
#   8. Print secrets reminder and next steps
#
# Options:
#   --nvme-device DEV    NVMe device to use (default: /dev/nvme0n1)
#   --no-hostname        Skip setting hostname to 'seabird'
#   --skip-storage       Skip install-storage.sh (NVMe already set up)
#   --skip-firewall      Skip install-firewall.sh
#   --skip-services      Skip install-services.sh
#
# Requirements:
#   - Fedora 44 aarch64 on Raspberry Pi CM4
#   - Internet access (dnf packages, container images pulled later on first start)
#   - Run as root

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NVME_DEVICE="/dev/nvme0n1"
SET_HOSTNAME=true
SKIP_STORAGE=false
SKIP_FIREWALL=false
SKIP_SERVICES=false

# ── argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nvme-device)   NVME_DEVICE="$2"; shift 2 ;;
        --no-hostname)   SET_HOSTNAME=false; shift ;;
        --skip-storage)  SKIP_STORAGE=true; shift ;;
        --skip-firewall) SKIP_FIREWALL=true; shift ;;
        --skip-services) SKIP_SERVICES=true; shift ;;
        -h|--help)
            sed -n '/^# bootstrap/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) echo "error: unknown option '$1'" >&2; exit 1 ;;
    esac
done

# ── guards ────────────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root (sudo scripts/bootstrap.sh)" >&2
    exit 1
fi

# ── helpers ───────────────────────────────────────────────────────────────────

section() { echo; echo "══════════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════════"; }
ok()      { echo "  ✓ $*"; }
info()    { echo "  → $*"; }

# ── 1. Host packages ─────────────────────────────────────────────────────────

section "1/7  Installing host packages"

DNF_PACKAGES=(
    # Networking
    NetworkManager
    firewalld
    iw
    iproute
    # Modem
    ModemManager
    libqmi
    libmbim
    # Storage
    btrfs-progs
    # Containers
    podman
    # Firmware (includes qcom SDX55 files)
    linux-firmware
    # Misc tools
    git
    jq
)

info "Running dnf install (this may take a minute)..."
dnf install -y "${DNF_PACKAGES[@]}"
ok "Packages installed"

# ── 2. PCIe DMA workaround for 5G modem ──────────────────────────────────────

section "2/7  PCIe 32-bit DMA overlay (5G modem fix)"

CONFIG_TXT="/boot/efi/config.txt"
OVERLAY_LINE="dtoverlay=pcie-32bit-dma"

if [[ ! -f "${CONFIG_TXT}" ]]; then
    echo "warning: ${CONFIG_TXT} not found — skipping overlay (not a RPi?)" >&2
elif grep -qxF "${OVERLAY_LINE}" "${CONFIG_TXT}"; then
    ok "${OVERLAY_LINE} already present in ${CONFIG_TXT}"
else
    echo "${OVERLAY_LINE}" >> "${CONFIG_TXT}"
    ok "Added ${OVERLAY_LINE} to ${CONFIG_TXT}"
    info "A reboot is required for the 5G modem to work — bootstrap will continue"
fi

# ── 3. Hostname ───────────────────────────────────────────────────────────────

section "3/7  Hostname"

if [[ "${SET_HOSTNAME}" == true ]]; then
    current_hostname="$(hostnamectl --static)"
    if [[ "${current_hostname}" == "seabird" ]]; then
        ok "Hostname already set to 'seabird'"
    else
        hostnamectl set-hostname seabird
        ok "Hostname set to 'seabird' (was '${current_hostname}')"
    fi
else
    info "Skipping hostname configuration (--no-hostname)"
fi

# ── 4. Storage ────────────────────────────────────────────────────────────────

section "4/7  Storage (NVMe btrfs layout)"

if [[ "${SKIP_STORAGE}" == true ]]; then
    info "Skipping storage setup (--skip-storage)"
else
    bash "${SCRIPT_DIR}/install-storage.sh" "${NVME_DEVICE}"
fi

# ── 5. Firewall ───────────────────────────────────────────────────────────────

section "5/7  Firewall (firewalld zones + Caddy)"

if [[ "${SKIP_FIREWALL}" == true ]]; then
    info "Skipping firewall setup (--skip-firewall)"
else
    bash "${SCRIPT_DIR}/install-firewall.sh"
fi

# ── 6. Services ───────────────────────────────────────────────────────────────

section "6/7  Services (Podman quadlets)"

if [[ "${SKIP_SERVICES}" == true ]]; then
    info "Skipping service setup (--skip-services)"
else
    bash "${SCRIPT_DIR}/install-services.sh"
fi

# ── 7. Podman auto-update timer ───────────────────────────────────────────────

section "7/7  Enabling podman-auto-update.timer"

systemctl enable --now podman-auto-update.timer
ok "podman-auto-update.timer enabled"

# ── Done ──────────────────────────────────────────────────────────────────────

echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Bootstrap complete — action required before starting        ║"
echo "║  services:                                                    ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                               ║"
echo "║  1. Populate secrets (one file per service):                  ║"
echo "║     /etc/seabird/influxdb.env                                 ║"
echo "║     /etc/seabird/grafana.env                                  ║"
echo "║     /etc/seabird/nextcloud.env                                ║"
echo "║     See docs/secrets-reference.md for required variables.    ║"
echo "║                                                               ║"
echo "║  2. If the pcie-32bit-dma overlay was just added:             ║"
echo "║     reboot now, then come back and start services.           ║"
echo "║                                                               ║"
echo "║  3. Start services:                                           ║"
echo "║     systemctl daemon-reload                                   ║"
echo "║     systemctl enable --now signalk influxdb grafana \\        ║"
echo "║       nextcloud-pod homepage                                  ║"
echo "║                                                               ║"
echo "║  4. Open dashboard:  http://seabird.local:3002               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo
