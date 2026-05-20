#!/usr/bin/env bash
# install-all.sh — install and start the full seabird stack
#
# Runs all install scripts in order, then enables and starts every service.
# Safe to re-run at any time — all steps are idempotent.
#
# Usage:
#   sudo scripts/install-all.sh [--nvme-device DEV] [--hostname NAME|--no-hostname]
#                               [--allow-wan-ssh=yes|no] [--mode=prod|dev]
#                               [--batch-network]
#                               [--background]
#                               [--crew-ssid NAME] [--crew-password PSK]
#                               [--crew-ip ADDR/PREFIX] [--crew-band bg|a]
#                               [--crew-pihole-ip IP]
#                               [--headscale-join=yes|no] [--headscale-login-server URL]
#                               [--headscale-auth-key KEY] [--skip-headscale]
#
# Options:
#   --nvme-device DEV        NVMe block device to use (default: /dev/nvme0n1)
#   --hostname NAME          Set static hostname (default: seabird)
#   --no-hostname            Skip hostname configuration
#   --allow-wan-ssh=yes|no   Open SSH on WAN zone with fail2ban (default: no)
#   --mode=prod|dev          Firewall mode for install-firewall.sh (default: prod)
#   --batch-network          Ask all network questions first, then run network
#                            setup scripts non-interactively with those answers
#   --background             Re-exec install-all in background and log to
#                            /var/log/seabird/install-all-<timestamp>.log
#   --crew-ssid NAME         WiFi AP SSID passed to install-crew-bridge.sh
#   --crew-password PSK      WiFi AP WPA2 password passed to install-crew-bridge.sh
#   --crew-ip ADDR/PREFIX    Crew bridge IP/prefix (default: 192.168.42.1/24)
#   --crew-band bg|a         Crew AP band: bg (2.4 GHz) or a (5 GHz)
#   --crew-pihole-ip IP      DNS IP advertised to DHCP clients (default: crew IP)
#   --headscale-join=yes|no  Join Headscale network during install (default: prompt)
#   --headscale-login-server Headscale control URL for tailscale up
#   --headscale-auth-key     Headscale preauth key for this node
#   --skip-headscale         Skip tailscale/headscale install + join step
#
# This script does NOT touch:
#   - Host OS packages (dnf)        → run scripts/bootstrap.sh for first-time setup
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
TARGET_HOSTNAME="seabird"
SET_HOSTNAME=true
SKIP_STORAGE=false
SKIP_FIREWALL=false
SKIP_AP=false
SKIP_SERVICES=false
SKIP_HEADSCALE=false
BATCH_NETWORK=false
BACKGROUND=false
ALLOW_WAN_SSH=""   # empty = let install-firewall.sh prompt
FIREWALL_MODE=""   # empty = let install-firewall.sh default to prod
CREW_SSID=""
CREW_PASSWORD=""
CREW_IP=""
CREW_BAND=""
CREW_PIHOLE_IP=""
HEADSCALE_JOIN=""            # empty = let install-headscale.sh prompt
HEADSCALE_LOGIN_SERVER=""
HEADSCALE_AUTH_KEY=""
RAW_ARGS=("$@")
NO_ARGS_RUN=false
if [[ ${#RAW_ARGS[@]} -eq 0 ]]; then
    NO_ARGS_RUN=true
fi

STATE_FILE="/etc/seabird/install-state.json"
STATE_STORAGE_VER="1"
STATE_FIREWALL_VER="1"
STATE_CREW_BRIDGE_VER="3"
STATE_SERVICES_VER="2"
STATE_HEADSCALE_VER="1"

declare -A INSTALL_STATE

load_install_state() {
    INSTALL_STATE=()
    if [[ ! -f "${STATE_FILE}" ]]; then
        return
    fi

    while IFS='=' read -r key value; do
        [[ -z "${key}" ]] && continue
        INSTALL_STATE["${key}"]="${value}"
    done < <(
        grep -Eo '"[^"]+"[[:space:]]*:[[:space:]]*"[^"]+"' "${STATE_FILE}" 2>/dev/null | \
            sed -E 's/"([^"]+)"[[:space:]]*:[[:space:]]*"([^"]+)"/\1=\2/'
    )
}

save_install_state() {
    local tmp
    tmp="$(mktemp)"
    mkdir -p "$(dirname "${STATE_FILE}")"

    mapfile -t _keys < <(printf '%s\n' "${!INSTALL_STATE[@]}" | sort)
    {
        printf '{\n'
        local i key value sep
        for ((i=0; i<${#_keys[@]}; i++)); do
            key="${_keys[$i]}"
            value="${INSTALL_STATE[$key]}"
            sep=","
            if [[ $i -eq $((${#_keys[@]} - 1)) ]]; then
                sep=""
            fi
            printf '  "%s": "%s"%s\n' "${key}" "${value}" "${sep}"
        done
        printf '}\n'
    } > "${tmp}"
    install -m 0644 "${tmp}" "${STATE_FILE}"
    rm -f "${tmp}"
}

mark_step_version() {
    local key="$1"
    local version="$2"
    INSTALL_STATE["${key}"]="${version}"
    save_install_state
}

should_run_step() {
    local key="$1"
    local version="$2"
    local label="$3"

    if [[ "${NO_ARGS_RUN}" != true || ! -t 0 ]]; then
        return 0
    fi

    if [[ "${INSTALL_STATE[$key]:-}" != "${version}" ]]; then
        return 0
    fi

    local answer
    read -r -p "Detected existing ${label} (state v${version}). Re-run? [y/N]: " answer
    [[ "${answer}" =~ ^[Yy]$ ]]
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nvme-device)       NVME_DEVICE="$2"; shift 2 ;;
        --hostname)          TARGET_HOSTNAME="$2"; shift 2 ;;
        --no-hostname)       SET_HOSTNAME=false; shift ;;
        --skip-storage)      SKIP_STORAGE=true; shift ;;
        --skip-firewall)     SKIP_FIREWALL=true; shift ;;
        --skip-ap)           SKIP_AP=true; shift ;;
        --skip-services)     SKIP_SERVICES=true; shift ;;
        --skip-headscale)    SKIP_HEADSCALE=true; shift ;;
        --batch-network)     BATCH_NETWORK=true; shift ;;
        --background)        BACKGROUND=true; shift ;;
        --allow-wan-ssh=yes) ALLOW_WAN_SSH=yes; shift ;;
        --allow-wan-ssh=no)  ALLOW_WAN_SSH=no;  shift ;;
        --crew-ssid)         CREW_SSID="${2:-}"; shift 2 ;;
        --crew-password)     CREW_PASSWORD="${2:-}"; shift 2 ;;
        --crew-ip)           CREW_IP="${2:-}"; shift 2 ;;
        --crew-band)         CREW_BAND="${2:-}"; shift 2 ;;
        --crew-pihole-ip)    CREW_PIHOLE_IP="${2:-}"; shift 2 ;;
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

if [[ -n "${CREW_BAND}" && "${CREW_BAND}" != "bg" && "${CREW_BAND}" != "a" ]]; then
    echo "error: --crew-band must be 'bg' or 'a'" >&2
    exit 1
fi

if [[ -n "${CREW_IP}" && ! "${CREW_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    echo "error: --crew-ip must be in ADDR/PREFIX format (e.g. 192.168.42.1/24)" >&2
    exit 1
fi

load_install_state

if [[ "${BATCH_NETWORK}" == true ]]; then
    if [[ ! -t 0 ]]; then
        echo "error: --batch-network requires an interactive terminal" >&2
        exit 1
    fi

    echo
    echo "Network batch preflight"
    echo "Answer once now; network steps will run non-interactively afterward."

    if [[ "${SKIP_FIREWALL}" != true ]]; then
        if [[ -z "${FIREWALL_MODE}" ]]; then
            read -r -p "Firewall mode [prod/dev] (default: prod): " FIREWALL_MODE
            FIREWALL_MODE="${FIREWALL_MODE:-prod}"
        fi
        while [[ "${FIREWALL_MODE}" != "prod" && "${FIREWALL_MODE}" != "dev" ]]; do
            read -r -p "Please enter firewall mode [prod/dev]: " FIREWALL_MODE
        done

        if [[ -z "${ALLOW_WAN_SSH}" ]]; then
            read -r -p "Allow SSH on WAN? [yes/no] (default: no): " ALLOW_WAN_SSH
            ALLOW_WAN_SSH="${ALLOW_WAN_SSH:-no}"
        fi
        while [[ "${ALLOW_WAN_SSH}" != "yes" && "${ALLOW_WAN_SSH}" != "no" ]]; do
            read -r -p "Please enter allow WAN SSH [yes/no]: " ALLOW_WAN_SSH
        done
    fi

    if [[ "${SKIP_AP}" != true ]]; then
        if [[ -z "${CREW_SSID}" ]]; then
            CURRENT_AP_SSID="$(nmcli -g 802-11-wireless.ssid con show seabird-ap 2>/dev/null || true)"
            CURRENT_AP_SSID="${CURRENT_AP_SSID//$'\n'/}"

            if [[ -n "${CURRENT_AP_SSID}" ]]; then
                read -r -p "Current AP SSID is '${CURRENT_AP_SSID}'. Change it? [y/N]: " _CHANGE_SSID
                if [[ "${_CHANGE_SSID}" =~ ^[Yy]$ ]]; then
                    while true; do
                        read -r -p "New Crew AP SSID: " CREW_SSID
                        [[ -n "${CREW_SSID}" ]] && break
                        echo "SSID must not be empty."
                    done
                else
                    CREW_SSID="${CURRENT_AP_SSID}"
                fi
            else
                while true; do
                    read -r -p "Crew AP SSID: " CREW_SSID
                    [[ -n "${CREW_SSID}" ]] && break
                    echo "SSID must not be empty."
                done
            fi
        fi

        if [[ -z "${CREW_PASSWORD}" ]]; then
            while true; do
                read -r -s -p "Crew AP WPA2 password (min 8 chars): " CREW_PASSWORD
                echo
                if [[ ${#CREW_PASSWORD} -lt 8 ]]; then
                    echo "Password must be at least 8 characters."
                    continue
                fi
                read -r -s -p "Confirm password: " _CREW_PASSWORD2
                echo
                if [[ "${CREW_PASSWORD}" == "${_CREW_PASSWORD2}" ]]; then
                    break
                fi
                echo "Passwords do not match — try again."
            done
        fi

        if [[ -z "${CREW_IP}" ]]; then
            read -r -p "Crew bridge IP/prefix (default: 192.168.42.1/24): " CREW_IP
            CREW_IP="${CREW_IP:-192.168.42.1/24}"
        fi
        while ! [[ "${CREW_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; do
            read -r -p "Please enter valid crew IP/prefix (e.g. 192.168.42.1/24): " CREW_IP
        done

        if [[ -z "${CREW_BAND}" ]]; then
            read -r -p "Crew AP band [bg/a] (default: bg): " CREW_BAND
            CREW_BAND="${CREW_BAND:-bg}"
        fi
        while [[ "${CREW_BAND}" != "bg" && "${CREW_BAND}" != "a" ]]; do
            read -r -p "Please enter AP band [bg/a]: " CREW_BAND
        done

        if [[ -z "${CREW_PIHOLE_IP}" ]]; then
            read -r -p "Crew DNS (Pi-hole) IP (default: crew bridge IP): " CREW_PIHOLE_IP
            CREW_PIHOLE_IP="${CREW_PIHOLE_IP:-${CREW_IP%%/*}}"
        fi
    fi

    echo
    echo "Network preflight summary"
    if [[ "${SKIP_FIREWALL}" != true ]]; then
        echo "  Firewall mode   : ${FIREWALL_MODE}"
        echo "  Allow WAN SSH   : ${ALLOW_WAN_SSH}"
    else
        echo "  Firewall        : skipped"
    fi
    if [[ "${SKIP_AP}" != true ]]; then
        echo "  Crew SSID       : ${CREW_SSID}"
        echo "  Crew password   : [set]"
        echo "  Crew bridge IP  : ${CREW_IP}"
        echo "  Crew AP band    : ${CREW_BAND}"
        echo "  Crew DNS IP     : ${CREW_PIHOLE_IP}"
    else
        echo "  Crew AP         : skipped"
    fi

    read -r -p "Proceed with these network settings? [y/N]: " _BATCH_CONFIRM
    if [[ ! "${_BATCH_CONFIRM}" =~ ^[Yy]$ ]]; then
        echo "Aborted by user."
        exit 1
    fi
fi

if [[ "${BACKGROUND}" == true && "${SEABIRD_INSTALL_ALL_DETACHED:-0}" != "1" ]]; then
    LOG_DIR="/var/log/seabird"
    TS="$(date +%Y%m%d-%H%M%S)"
    LOG_FILE="${LOG_DIR}/install-all-${TS}.log"
    mkdir -p "${LOG_DIR}"

    FORWARD_ARGS=()
    [[ "${SET_HOSTNAME}" == false ]] && FORWARD_ARGS+=(--no-hostname)
    [[ "${SKIP_STORAGE}" == true ]] && FORWARD_ARGS+=(--skip-storage)
    [[ "${SKIP_FIREWALL}" == true ]] && FORWARD_ARGS+=(--skip-firewall)
    [[ "${SKIP_AP}" == true ]] && FORWARD_ARGS+=(--skip-ap)
    [[ "${SKIP_SERVICES}" == true ]] && FORWARD_ARGS+=(--skip-services)
    [[ "${SKIP_HEADSCALE}" == true ]] && FORWARD_ARGS+=(--skip-headscale)
    [[ -n "${NVME_DEVICE}" ]] && FORWARD_ARGS+=(--nvme-device "${NVME_DEVICE}")
    [[ "${SET_HOSTNAME}" == true ]] && FORWARD_ARGS+=(--hostname "${TARGET_HOSTNAME}")
    [[ -n "${ALLOW_WAN_SSH}" ]] && FORWARD_ARGS+=(--allow-wan-ssh="${ALLOW_WAN_SSH}")
    [[ -n "${FIREWALL_MODE}" ]] && FORWARD_ARGS+=(--mode "${FIREWALL_MODE}")
    [[ -n "${CREW_SSID}" ]] && FORWARD_ARGS+=(--crew-ssid "${CREW_SSID}")
    [[ -n "${CREW_PASSWORD}" ]] && FORWARD_ARGS+=(--crew-password "${CREW_PASSWORD}")
    [[ -n "${CREW_IP}" ]] && FORWARD_ARGS+=(--crew-ip "${CREW_IP}")
    [[ -n "${CREW_BAND}" ]] && FORWARD_ARGS+=(--crew-band "${CREW_BAND}")
    [[ -n "${CREW_PIHOLE_IP}" ]] && FORWARD_ARGS+=(--crew-pihole-ip "${CREW_PIHOLE_IP}")
    [[ -n "${HEADSCALE_JOIN}" ]] && FORWARD_ARGS+=(--headscale-join="${HEADSCALE_JOIN}")
    [[ -n "${HEADSCALE_LOGIN_SERVER}" ]] && FORWARD_ARGS+=(--headscale-login-server "${HEADSCALE_LOGIN_SERVER}")
    [[ -n "${HEADSCALE_AUTH_KEY}" ]] && FORWARD_ARGS+=(--headscale-auth-key "${HEADSCALE_AUTH_KEY}")

    echo "Starting install-all in background..."
    echo "  Log file: ${LOG_FILE}"
    echo "  Follow:   tail -f ${LOG_FILE}"

    SEABIRD_INSTALL_ALL_DETACHED=1 nohup "$0" "${FORWARD_ARGS[@]}" >"${LOG_FILE}" 2>&1 < /dev/null &
    echo "  PID: $!"
    exit 0
fi

section() { echo; echo "══════════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════════"; }

# ── 1. Hostname ───────────────────────────────────────────────────────────────

section "1/7  Hostname"
if [[ "${SET_HOSTNAME}" == true ]]; then
    current_hostname="$(hostnamectl --static 2>/dev/null || hostname)"
    if [[ "${current_hostname}" == "${TARGET_HOSTNAME}" ]]; then
        echo "  hostname already set to '${TARGET_HOSTNAME}'"
    else
        hostnamectl set-hostname "${TARGET_HOSTNAME}"
        echo "  hostname set to '${TARGET_HOSTNAME}' (was '${current_hostname}')"
    fi
else
    echo "  skipping (--no-hostname)"
fi

# ── 2. Storage ────────────────────────────────────────────────────────────────

section "2/7  Storage"
if [[ "${SKIP_STORAGE}" == true ]]; then
    echo "  skipping (--skip-storage)"
else
    if should_run_step "storage" "${STATE_STORAGE_VER}" "storage setup"; then
        bash "${SCRIPT_DIR}/install-storage.sh" "${NVME_DEVICE}"
        mark_step_version "storage" "${STATE_STORAGE_VER}"
    else
        echo "  keeping existing storage setup"
    fi
fi

# ── 3. Firewall + Caddy config ────────────────────────────────────────────────

section "3/7  Firewall"
if [[ "${SKIP_FIREWALL}" == true ]]; then
    echo "  skipping (--skip-firewall)"
else
    if should_run_step "firewall" "${STATE_FIREWALL_VER}" "firewall setup"; then
        FIREWALL_ARGS=()
        [[ -n "${ALLOW_WAN_SSH}" ]] && FIREWALL_ARGS+=("--allow-wan-ssh=${ALLOW_WAN_SSH}")
        [[ -n "${FIREWALL_MODE}" ]] && FIREWALL_ARGS+=("--mode=${FIREWALL_MODE}")
        bash "${SCRIPT_DIR}/install-firewall.sh" "${FIREWALL_ARGS[@]}"
        mark_step_version "firewall" "${STATE_FIREWALL_VER}"
    else
        echo "  keeping existing firewall setup"
    fi
fi

# ── 4. Wired crew LAN + WiFi access point ────────────────────────────────────

section "4/7  Crew LAN + WiFi access point"
if [[ -f "${SCRIPT_DIR}/install-crew-bridge.sh" ]]; then
    if [[ "${SKIP_AP}" == true ]]; then
        echo "  skipping (--skip-ap)"
    else
        if should_run_step "crew-bridge" "${STATE_CREW_BRIDGE_VER}" "crew bridge/AP setup"; then
            echo "  configuring unified crew LAN bridge (wired + AP)..."
            BRIDGE_ARGS=()
            [[ -n "${CREW_SSID}" ]] && BRIDGE_ARGS+=(--ssid "${CREW_SSID}")
            [[ -n "${CREW_PASSWORD}" ]] && BRIDGE_ARGS+=(--password "${CREW_PASSWORD}")
            [[ -n "${CREW_IP}" ]] && BRIDGE_ARGS+=(--ip "${CREW_IP}")
            [[ -n "${CREW_BAND}" ]] && BRIDGE_ARGS+=(--band "${CREW_BAND}")
            [[ -n "${CREW_PIHOLE_IP}" ]] && BRIDGE_ARGS+=(--pihole-ip "${CREW_PIHOLE_IP}")
            bash "${SCRIPT_DIR}/install-crew-bridge.sh" "${BRIDGE_ARGS[@]}"
            mark_step_version "crew-bridge" "${STATE_CREW_BRIDGE_VER}"
        else
            echo "  keeping existing crew bridge/AP setup"
        fi
    fi
else
    echo "  configuring wired crew LAN..."
    bash "${SCRIPT_DIR}/install-crew-lan.sh"

    if [[ "${SKIP_AP}" == true ]]; then
        echo "  skipping (--skip-ap)"
    else
        AP_ARGS=()
        [[ -n "${CREW_SSID}" ]] && AP_ARGS+=(--ssid "${CREW_SSID}")
        [[ -n "${CREW_PASSWORD}" ]] && AP_ARGS+=(--password "${CREW_PASSWORD}")
        [[ -n "${CREW_IP}" ]] && AP_ARGS+=(--ip "${CREW_IP}")
        [[ -n "${CREW_BAND}" ]] && AP_ARGS+=(--band "${CREW_BAND}")
        bash "${SCRIPT_DIR}/install-ap.sh" "${AP_ARGS[@]}"
    fi
fi

# ── 5. Service quadlets ───────────────────────────────────────────────────────

section "5/7  Services"
if [[ "${SKIP_SERVICES}" == true ]]; then
    echo "  skipping (--skip-services)"
else
    if should_run_step "services" "${STATE_SERVICES_VER}" "services setup"; then
        bash "${SCRIPT_DIR}/install-services.sh"
        mark_step_version "services" "${STATE_SERVICES_VER}"
    else
        echo "  keeping existing services setup"
    fi
fi

# ── 6. Headscale / Tailscale join ────────────────────────────────────────────

section "6/7  Headscale network"
if [[ "${SKIP_HEADSCALE}" == true ]]; then
    echo "  skipping (--skip-headscale)"
else
    if should_run_step "headscale" "${STATE_HEADSCALE_VER}" "headscale setup"; then
        HEADSCALE_ARGS=()
        [[ -n "${HEADSCALE_JOIN}" ]] && HEADSCALE_ARGS+=("--join=${HEADSCALE_JOIN}")
        [[ -n "${HEADSCALE_LOGIN_SERVER}" ]] && HEADSCALE_ARGS+=("--login-server" "${HEADSCALE_LOGIN_SERVER}")
        [[ -n "${HEADSCALE_AUTH_KEY}" ]] && HEADSCALE_ARGS+=("--auth-key" "${HEADSCALE_AUTH_KEY}")
        bash "${SCRIPT_DIR}/install-headscale.sh" "${HEADSCALE_ARGS[@]}"
        mark_step_version "headscale" "${STATE_HEADSCALE_VER}"
    else
        echo "  keeping existing headscale setup"
    fi
fi

# ── 7. Enable and start all services ─────────────────────────────────────────

section "7/7  Starting services"

# install-services.sh already ran daemon-reload; run it once more here only
# if services were skipped (so quadlet generator output is always fresh)
if [[ "${SKIP_SERVICES}" == true ]]; then
    systemctl daemon-reload
fi

# Quadlet generator writes to /run/systemd/generator/
GEN_DIR="/run/systemd/generator"
QUADLET_UNITS=$(ls "${GEN_DIR}"/*.service "${GEN_DIR}"/*.pod 2>/dev/null | \
    grep -E "caddy|signalk|influxdb|grafana|nextcloud|homepage|pihole|navidrome|avnav" || true)

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
    avnav
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
echo "  AvNav:      http://seabird.local:8080"
echo
echo "Check service status with:  systemctl status caddy signalk influxdb grafana avnav"
echo "View logs with:             journalctl -u <service> -f"
echo
# Warn if any secrets files are still empty
for f in nextcloud influxdb grafana; do
    env_file="/etc/seabird/${f}.env"
    if [[ -f "${env_file}" && ! -s "${env_file}" ]]; then
        echo "  WARNING: /etc/seabird/${f}.env is empty — populate and restart ${f}.service"
    fi
done
