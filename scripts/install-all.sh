#!/usr/bin/env bash
# install-all.sh — install and start the full seabird stack
#
# Runs all install scripts in order, then enables and starts every service.
# Safe to re-run at any time — all steps are idempotent.
#
# Usage:
#   sudo scripts/install-all.sh [--nvme-device DEV] [--allow-wan-ssh=yes|no]
#
# Options:
#   --nvme-device DEV        NVMe block device to use (default: /dev/nvme0n1)
#   --allow-wan-ssh=yes|no   Open SSH on WAN zone with fail2ban (default: no)
#
# This script does NOT touch:
#   - Host OS packages (dnf)        → run scripts/bootstrap.sh for first-time setup
#   - Hostname                      → run scripts/bootstrap.sh
#   - PCIe DMA overlay              → run scripts/bootstrap.sh
#   - Per-user Nextcloud mounts     → run scripts/add-user.sh <username>
#
# Secrets must be populated before services will start correctly:
#   /etc/seabird/nextcloud.env
#   /etc/seabird/influxdb.env
#   /etc/seabird/grafana.env
# See /etc/seabird/*.env.example for required variables.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NVME_DEVICE="/dev/nvme0n1"
SKIP_STORAGE=false
SKIP_FIREWALL=false
SKIP_AP=false
SKIP_SERVICES=false
ALLOW_WAN_SSH=""   # empty = let install-firewall.sh prompt

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nvme-device)       NVME_DEVICE="$2"; shift 2 ;;
        --skip-storage)      SKIP_STORAGE=true; shift ;;
        --skip-firewall)     SKIP_FIREWALL=true; shift ;;
        --skip-ap)           SKIP_AP=true; shift ;;
        --skip-services)     SKIP_SERVICES=true; shift ;;
        --allow-wan-ssh=yes) ALLOW_WAN_SSH=yes; shift ;;
        --allow-wan-ssh=no)  ALLOW_WAN_SSH=no;  shift ;;
        --allow-wan-ssh)
            if [[ "${2:-}" == "yes" || "${2:-}" == "no" ]]; then
                ALLOW_WAN_SSH="$2"; shift 2
            else
                echo "error: --allow-wan-ssh requires 'yes' or 'no'" >&2; exit 1
            fi ;;
        -h|--help)
            sed -n '/^# install-all/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) echo "error: unknown option '$1'" >&2; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root" >&2
    exit 1
fi

section() { echo; echo "══════════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════════"; }

# ── 1. Storage ────────────────────────────────────────────────────────────────

section "1/5  Storage"
if [[ "${SKIP_STORAGE}" == true ]]; then
    echo "  skipping (--skip-storage)"
else
    bash "${SCRIPT_DIR}/install-storage.sh" "${NVME_DEVICE}"
fi

# ── 2. Firewall + Caddy config ────────────────────────────────────────────────

section "2/5  Firewall"
if [[ "${SKIP_FIREWALL}" == true ]]; then
    echo "  skipping (--skip-firewall)"
else
    FIREWALL_ARGS=()
    [[ -n "${ALLOW_WAN_SSH}" ]] && FIREWALL_ARGS+=("--allow-wan-ssh=${ALLOW_WAN_SSH}")
    bash "${SCRIPT_DIR}/install-firewall.sh" "${FIREWALL_ARGS[@]}"
fi

# ── 3. WiFi access point ──────────────────────────────────────────────────────

section "3/5  WiFi access point"
if [[ "${SKIP_AP}" == true ]]; then
    echo "  skipping (--skip-ap)"
else
    bash "${SCRIPT_DIR}/install-ap.sh"
fi

# ── 4. Service quadlets ───────────────────────────────────────────────────────

section "4/5  Services"
if [[ "${SKIP_SERVICES}" == true ]]; then
    echo "  skipping (--skip-services)"
else
    bash "${SCRIPT_DIR}/install-services.sh"
fi

# ── 5. Enable and start all services ─────────────────────────────────────────

section "5/5  Starting services"

# Reload to pick up any newly installed quadlets / systemd units
systemctl daemon-reload

# Quadlet generator writes to /run/systemd/generator/ — check it produced output
GEN_DIR="/run/systemd/generator"
QUADLET_UNITS=$(ls "${GEN_DIR}"/*.service "${GEN_DIR}"/*.pod 2>/dev/null | \
    grep -E "caddy|signalk|influxdb|grafana|nextcloud|homepage" || true)

if [[ -z "${QUADLET_UNITS}" ]]; then
    echo "  WARNING: quadlet generator produced no units — running generator manually to capture errors:"
    mkdir -p /tmp/quadlet-gen-test
    /usr/lib/systemd/system-generators/podman-system-generator \
        /tmp/quadlet-gen-test /tmp/quadlet-gen-test /tmp/quadlet-gen-test 2>&1 || true
    echo "  Generator test output in /tmp/quadlet-gen-test/:"
    ls /tmp/quadlet-gen-test/ 2>/dev/null || echo "    (empty)"
    echo "  Also check: journalctl -b | grep -i quadlet"
    echo
fi

SERVICES=(
    caddy
    influxdb
    signalk
    grafana
    nextcloud-pod
    homepage
)

for svc in "${SERVICES[@]}"; do
    unit="${svc}.service"
    if systemctl show "${unit}" --property=LoadState 2>/dev/null | grep -q "LoadState=loaded"; then
        systemctl start "${unit}"
        echo "  ✓ ${unit}"
    else
        echo "  ✗ ${unit} not found — skipping" >&2
    fi
done

# Enable podman auto-update timer
systemctl enable --now podman-auto-update.timer
echo "  ✓ podman-auto-update.timer"

# ── Done ──────────────────────────────────────────────────────────────────────

echo
echo "All services started."
echo
echo "  Dashboard:  http://seabird.local:3002"
echo "  Nextcloud:  http://seabird.local:8080"
echo "  Signal-K:   http://seabird.local:3000"
echo "  Grafana:    http://seabird.local:3001"
echo
echo "Check service status with:  systemctl status caddy signalk influxdb grafana"
echo "View logs with:             journalctl -u <service> -f"
echo
# Warn if any secrets files are still empty
for f in nextcloud influxdb grafana; do
    env_file="/etc/seabird/${f}.env"
    if [[ -f "${env_file}" && ! -s "${env_file}" ]]; then
        echo "  WARNING: /etc/seabird/${f}.env is empty — populate and restart ${f}.service"
    fi
done
