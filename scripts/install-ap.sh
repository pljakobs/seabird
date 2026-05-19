#!/usr/bin/env bash
# install-ap.sh — configure wlp6s0 as a WiFi access point for the crew LAN
#
# Uses NetworkManager with ipv4.method=shared which also runs a dnsmasq
# instance for DHCP and DNS on the AP interface.
#
# Usage:
#   sudo scripts/install-ap.sh
#   sudo scripts/install-ap.sh --ssid SeaBird --ip 192.168.42.1/24
#
# Options (all are prompted interactively if not provided):
#   --ssid NAME      WiFi network name
#   --password PSK   WPA2 passphrase (min 8 characters)
#   --ip ADDR/PREFIX AP IP address and prefix length (default: 192.168.42.1/24)
#   --band BAND      WiFi band: bg (2.4 GHz) or a (5 GHz, default: bg)
#
# Safe to re-run — existing seabird-ap NM connection is replaced.

set -euo pipefail

AP_IFACE="wlp6s0"
NM_CONN="seabird-ap"
SEABIRD_AP_CONF="/etc/NetworkManager/dnsmasq-shared.d/seabird-ap.conf"

SSID=""
PASSWORD=""
AP_IP=""
BAND="bg"

# ── argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssid)     SSID="$2";     shift 2 ;;
        --password) PASSWORD="$2"; shift 2 ;;
        --ip)       AP_IP="$2";    shift 2 ;;
        --band)     BAND="$2";     shift 2 ;;
        -h|--help)
            sed -n '/^# install-ap/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) echo "error: unknown option '$1'" >&2; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root" >&2
    exit 1
fi

# ── check if already configured ──────────────────────────────────────────────

if nmcli con show "${NM_CONN}" &>/dev/null; then
    EXISTING_SSID=$(nmcli -g 802-11-wireless.ssid con show "${NM_CONN}" 2>/dev/null || true)
    EXISTING_IP=$(nmcli -g ipv4.addresses con show "${NM_CONN}" 2>/dev/null || true)
    echo "AP '${NM_CONN}' is already configured:"
    echo "  SSID : ${EXISTING_SSID}"
    echo "  IP   : ${EXISTING_IP}"
    echo
    # If all values were supplied non-interactively via args, skip prompt and reconfigure
    if [[ -n "${SSID}" && -n "${PASSWORD}" && -n "${AP_IP}" ]]; then
        echo "All parameters provided — reconfiguring."
    else
        read -r -p "Reconfigure? [y/N]: " RECONFIGURE
        if [[ ! "${RECONFIGURE}" =~ ^[Yy]$ ]]; then
            echo "Leaving AP configuration unchanged."
            exit 0
        fi
    fi
fi

# ── interactive prompts for anything not supplied on command line ─────────────

if [[ -z "${SSID}" ]]; then
    read -r -p "AP SSID [SeaBird]: " SSID
    SSID="${SSID:-SeaBird}"
fi

if [[ -z "${PASSWORD}" ]]; then
    while true; do
        read -r -s -p "AP WPA2 password (min 8 chars): " PASSWORD
        echo
        if [[ ${#PASSWORD} -ge 8 ]]; then
            read -r -s -p "Confirm password: " PASSWORD2
            echo
            if [[ "${PASSWORD}" == "${PASSWORD2}" ]]; then
                break
            else
                echo "Passwords do not match — try again."
            fi
        else
            echo "Password must be at least 8 characters."
        fi
    done
fi

if [[ -z "${AP_IP}" ]]; then
    read -r -p "AP IP address with prefix [192.168.42.1/24]: " AP_IP
    AP_IP="${AP_IP:-192.168.42.1/24}"
fi

# Validate IP/prefix format
if ! [[ "${AP_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    echo "error: invalid IP/prefix format '${AP_IP}' — expected e.g. 192.168.42.1/24" >&2
    exit 1
fi

if [[ "${BAND}" != "bg" && "${BAND}" != "a" ]]; then
    echo "error: --band must be 'bg' (2.4 GHz) or 'a' (5 GHz)" >&2
    exit 1
fi

# Derive DHCP range from the AP IP (use .10–.200 within the subnet)
AP_BASE="${AP_IP%.*}"   # e.g. 192.168.42
DHCP_START="${AP_BASE}.10"
DHCP_END="${AP_BASE}.200"

echo
echo "Configuring AP:"
echo "  Interface : ${AP_IFACE}"
echo "  SSID      : ${SSID}"
echo "  Band      : ${BAND} ($([ "${BAND}" = "a" ] && echo "5 GHz" || echo "2.4 GHz"))"
echo "  AP IP     : ${AP_IP}"
echo "  DHCP      : ${DHCP_START} – ${DHCP_END}"
echo

# ── remove existing connection ────────────────────────────────────────────────

if nmcli con show "${NM_CONN}" &>/dev/null; then
    echo "Removing existing '${NM_CONN}' connection..."
    nmcli con delete "${NM_CONN}"
fi

# ── create AP connection ──────────────────────────────────────────────────────

echo "Creating AP connection..."
nmcli con add \
    type wifi \
    ifname "${AP_IFACE}" \
    con-name "${NM_CONN}" \
    ssid "${SSID}" \
    mode ap

nmcli con modify "${NM_CONN}" \
    802-11-wireless.band "${BAND}" \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk "${PASSWORD}" \
    ipv4.method shared \
    ipv4.addresses "${AP_IP}" \
    ipv6.method disabled \
    connection.autoconnect yes

# ── DHCP range ────────────────────────────────────────────────────────────────
# NM shared mode runs dnsmasq; custom range goes in dnsmasq-shared.d/

mkdir -p /etc/NetworkManager/dnsmasq-shared.d
AP_ADDR="${AP_IP%%/*}"   # strip prefix length, e.g. 192.168.42.1 from 192.168.42.1/24
cat > "${SEABIRD_AP_CONF}" <<EOF
# seabird AP DHCP config — managed by install-ap.sh, do not edit manually
dhcp-range=${DHCP_START},${DHCP_END},12h
# Hand out Pi-hole as primary DNS, with Quad9 fallback if Pi-hole is unavailable
dhcp-option=6,${AP_ADDR},9.9.9.9
EOF
echo "  DHCP range and DNS configured in ${SEABIRD_AP_CONF}"

# ── register seabird.local in Pi-hole custom DNS ──────────────────────────────

PIHOLE_CUSTOM_LIST="/srv/seabird/pihole/etc-pihole/custom.list"
if [[ -d /srv/seabird/pihole ]]; then
    mkdir -p /srv/seabird/pihole/etc-pihole
    # Replace or add seabird entry so re-runs stay idempotent
    if grep -q "seabird" "${PIHOLE_CUSTOM_LIST}" 2>/dev/null; then
        sed -i "s/^.* seabird\.local.*$/${AP_ADDR} seabird.local seabird/" "${PIHOLE_CUSTOM_LIST}"
        echo "  Updated seabird.local DNS entry → ${AP_ADDR}"
    else
        echo "${AP_ADDR} seabird.local seabird" >> "${PIHOLE_CUSTOM_LIST}"
        echo "  Added seabird.local DNS entry → ${AP_ADDR}"
    fi
else
    echo "  Note: /srv/seabird/pihole not mounted yet; run install-services.sh to create dirs,"
    echo "        then re-run install-ap.sh to write the seabird.local DNS entry."
fi

# ── bring it up ───────────────────────────────────────────────────────────────

echo "Activating AP..."
nmcli con up "${NM_CONN}"

echo
echo "AP '${SSID}' is active on ${AP_IFACE} (${AP_IP})"
echo "DHCP range: ${DHCP_START} – ${DHCP_END}"
