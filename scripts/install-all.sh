#!/usr/bin/env bash
# install-all.sh — install and start the full seabird stack
#
# Runs all install scripts in order, then enables and starts every service.
# Safe to re-run at any time — all steps are idempotent.
#
# Usage:
#   sudo scripts/install-all.sh [--nvme-device DEV] [--allow-wan-ssh=yes|no] [--mode=prod|dev]
#                               [--headscale-join=yes|no] [--headscale-login-server URL]
#                               [--headscale-auth-key KEY] [--skip-headscale]
#
# Options:
#   --nvme-device DEV        NVMe block device to use (default: /dev/nvme0n1)
#   --allow-wan-ssh=yes|no   Open SSH on WAN zone with fail2ban (default: no)
#   --mode=prod|dev          Firewall mode for install-firewall.sh (default: prod)
#   --headscale-join=yes|no  Join Headscale network during install (default: prompt)
#   --headscale-login-server Headscale control URL for tailscale up
#   --headscale-auth-key     Headscale preauth key for this node
#   --skip-headscale         Skip tailscale/headscale install + join step
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
SKIP_HEADSCALE=false
ALLOW_WAN_SSH=""   # empty = let install-firewall.sh prompt
FIREWALL_MODE=""   # empty = let install-firewall.sh default to prod
HEADSCALE_JOIN=""            # empty = let install-headscale.sh prompt
HEADSCALE_LOGIN_SERVER=""
HEADSCALE_AUTH_KEY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nvme-device)       NVME_DEVICE="$2"; shift 2 ;;
        --skip-storage)      SKIP_STORAGE=true; shift ;;
        --skip-firewall)     SKIP_FIREWALL=true; shift ;;
        --skip-ap)           SKIP_AP=true; shift ;;
        --skip-services)     SKIP_SERVICES=true; shift ;;
        --skip-headscale)    SKIP_HEADSCALE=true; shift ;;
        --allow-wan-ssh=yes) ALLOW_WAN_SSH=yes; shift ;;
        --allow-wan-ssh=no)  ALLOW_WAN_SSH=no;  shift ;;
        --allow-wan-ssh)
            if [[ "${2:-}" == "yes" || "${2:-}" == "no" ]]; then
                ALLOW_WAN_SSH="$2"; shift 2
            else
                echo "error: --allow-wan-ssh requires 'yes' or 'no'" >&2; exit 1
            fi ;;
        --mode=prod) FIREWALL_MODE=prod; shift ;;
        --mode=dev)  FIREWALL_MODE=dev;  shift ;;
        --mode)
            if [[ "${2:-}" == "prod" || "${2:-}" == "dev" ]]; then
                FIREWALL_MODE="$2"; shift 2
            else
                echo "error: --mode requires 'prod' or 'dev'" >&2; exit 1
            fi ;;
        --headscale-join=yes) HEADSCALE_JOIN=yes; shift ;;
        --headscale-join=no)  HEADSCALE_JOIN=no;  shift ;;
        --headscale-join)
            if [[ "${2:-}" == "yes" || "${2:-}" == "no" ]]; then
                HEADSCALE_JOIN="$2"; shift 2
            else
                echo "error: --headscale-join requires 'yes' or 'no'" >&2; exit 1
            fi ;;
        --headscale-login-server)
            HEADSCALE_LOGIN_SERVER="${2:-}"; shift 2 ;;
        --headscale-auth-key)
            HEADSCALE_AUTH_KEY="${2:-}"; shift 2 ;;
        -h|--help)
            sed -n '/^# install-all/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) echo "error: unknown option '$1'" >&2; exit 1 ;;
    esac
done

# If an auth key is provided, treat it as explicit intent to auto-join.
if [[ -n "${HEADSCALE_AUTH_KEY}" && -z "${HEADSCALE_JOIN}" ]]; then
    HEADSCALE_JOIN=yes
fi

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
    [[ -n "${FIREWALL_MODE}" ]] && FIREWALL_ARGS+=("--mode=${FIREWALL_MODE}")
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

# ── 5. Headscale / Tailscale join ────────────────────────────────────────────

section "5/6  Headscale network"
if [[ "${SKIP_HEADSCALE}" == true ]]; then
    echo "  skipping (--skip-headscale)"
else
    HEADSCALE_ARGS=()
    [[ -n "${HEADSCALE_JOIN}" ]] && HEADSCALE_ARGS+=("--join=${HEADSCALE_JOIN}")
    [[ -n "${HEADSCALE_LOGIN_SERVER}" ]] && HEADSCALE_ARGS+=("--login-server" "${HEADSCALE_LOGIN_SERVER}")
    [[ -n "${HEADSCALE_AUTH_KEY}" ]] && HEADSCALE_ARGS+=("--auth-key" "${HEADSCALE_AUTH_KEY}")
    bash "${SCRIPT_DIR}/install-headscale.sh" "${HEADSCALE_ARGS[@]}"
fi

# ── 6. Enable and start all services ─────────────────────────────────────────

section "6/6  Starting services"

# install-services.sh already ran daemon-reload; run it once more here only
# if services were skipped (so quadlet generator output is always fresh)
if [[ "${SKIP_SERVICES}" == true ]]; then
    systemctl daemon-reload
fi

# Quadlet generator writes to /run/systemd/generator/
GEN_DIR="/run/systemd/generator"
QUADLET_UNITS=$(ls "${GEN_DIR}"/*.service "${GEN_DIR}"/*.pod 2>/dev/null | \
    grep -E "caddy|signalk|influxdb|grafana|nextcloud|homepage|pihole|navidrome" || true)

if [[ -z "${QUADLET_UNITS}" ]]; then
    echo "  WARNING: quadlet generator produced no units — dumping generator errors:"
    mkdir -p /tmp/quadlet-gen-test
    /usr/lib/systemd/system-generators/podman-system-generator \
        /tmp/quadlet-gen-test /tmp/quadlet-gen-test /tmp/quadlet-gen-test 2>&1 || true
    echo "  Generator test output in /tmp/quadlet-gen-test/:"
    ls /tmp/quadlet-gen-test/ 2>/dev/null || echo "    (empty)"
    echo "  Check quadlet syntax: journalctl -b | grep -i quadlet"
    echo
fi

SERVICES=(
    caddy
    influxdb
    signalk
    grafana
    nextcloud-pod
    homepage
    pihole
    navidrome
)

for svc in "${SERVICES[@]}"; do
    unit="${svc}.service"
    # Check the generator output directly — more reliable than LoadState after
    # a daemon-reload that may have partially failed
    if [[ -f "${GEN_DIR}/${unit}" ]]; then
        if systemctl start "${unit}"; then
            echo "  ✓ ${unit}"
        else
            echo "  ✗ ${unit} failed to start — check: journalctl -u ${unit} -e" >&2
        fi
    else
        echo "  ✗ ${unit} not in generator output — quadlet error?" >&2
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
