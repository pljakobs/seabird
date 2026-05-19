#!/usr/bin/env bash
# install-crew-bridge.sh — configure br-crew bridge for unified crew LAN
#
# Bridges wlp6s0 (WiFi AP) and enp4s0 (wired) into a single LAN segment.
# Both interfaces serve DHCP from the same bridge IP and subnet, with DNS
# forwarded to the pihole instance.
#
# Usage:
#   sudo scripts/install-crew-bridge.sh
#   sudo scripts/install-crew-bridge.sh --ssid SeaBird --password mysecret --ip 192.168.42.1/24
#
# Options (all are prompted interactively if not provided):
#   --ssid NAME      WiFi network name
#   --password PSK   WPA2 passphrase (min 8 characters)
#   --ip ADDR/PREFIX Bridge IP address and prefix length (default: 192.168.42.1/24)
#   --pihole-ip IP   pihole DNS server IP (default: bridge IP; pihole listens on 0.0.0.0:53)
#   --band BAND      WiFi band: bg (2.4 GHz) or a (5 GHz, default: bg)
#
# Safe to re-run — existing connections are replaced.

set -euo pipefail

AP_IFACE="wlp6s0"
WIRED_IFACE="enp4s0"
BRIDGE_NAME="br-crew"
NM_BRIDGE_CONN="crew-lan-bridge"
NM_AP_CONN="seabird-ap"
NM_WIRED_CONN="seabird-wired-member"
SEABIRD_BRIDGE_CONF="/etc/NetworkManager/dnsmasq-shared.d/seabird-crew-bridge.conf"

SSID=""
PASSWORD=""
BRIDGE_IP=""
PIHOLE_IP=""  # pihole DNS server (defaults to bridge IP; pihole listens on 0.0.0.0:53)
BAND="bg"

# ── argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssid)     SSID="$2";     shift 2 ;;
        --password) PASSWORD="$2"; shift 2 ;;
        --ip)       BRIDGE_IP="$2";    shift 2 ;;
        --pihole-ip) PIHOLE_IP="$2"; shift 2 ;;
        --band)     BAND="$2";     shift 2 ;;
        -h|--help)
            sed -n '/^# install-crew-bridge/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) echo "error: unknown option '$1'" >&2; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root" >&2
    exit 1
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

if [[ -z "${BRIDGE_IP}" ]]; then
    read -r -p "Bridge IP address with prefix [192.168.42.1/24]: " BRIDGE_IP
    BRIDGE_IP="${BRIDGE_IP:-192.168.42.1/24}"
fi

# Validate IP/prefix format
if ! [[ "${BRIDGE_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    echo "error: invalid IP/prefix format '${BRIDGE_IP}' — expected e.g. 192.168.42.1/24" >&2
    exit 1
fi

# Set pihole IP to bridge IP if not provided (pihole listens on 0.0.0.0:53)
BRIDGE_ADDR="${BRIDGE_IP%%/*}"   # e.g. 192.168.42.1
if [[ -z "${PIHOLE_IP}" ]]; then
    PIHOLE_IP="${BRIDGE_ADDR}"
fi

if [[ "${BAND}" != "bg" && "${BAND}" != "a" ]]; then
    echo "error: --band must be 'bg' (2.4 GHz) or 'a' (5 GHz)" >&2
    exit 1
fi

# Derive DHCP range from the bridge IP (use .10–.200 within the subnet)
BRIDGE_BASE="${BRIDGE_IP%.*}"   # e.g. 192.168.42
DHCP_START="${BRIDGE_BASE}.10"
DHCP_END="${BRIDGE_BASE}.200"

echo
echo "Configuring unified crew LAN bridge:"
echo "  Bridge      : ${BRIDGE_NAME}"
echo "  Members     : ${AP_IFACE}, ${WIRED_IFACE}"
echo "  WiFi SSID   : ${SSID}"
echo "  WiFi Band   : ${BAND} ($([ "${BAND}" = "a" ] && echo "5 GHz" || echo "2.4 GHz"))"
echo "  Bridge IP   : ${BRIDGE_IP}"
echo "  DHCP range  : ${DHCP_START} – ${DHCP_END}"
echo "  DNS server  : ${PIHOLE_IP} (pihole)"
echo

# ── clean up old individual connections ─────────────────────────────────────

echo "Cleaning up old individual LAN connections..."
for old_conn in "seabird-ap" "Wired connection 2" "seabird-wired-member"; do
    if nmcli con show "${old_conn}" &>/dev/null; then
        echo "  Removing old connection '${old_conn}'..."
        nmcli con down "${old_conn}" 2>/dev/null || true
        nmcli con delete "${old_conn}"
    fi
done

# ── remove old bridge if it exists ──────────────────────────────────────────

if nmcli con show "${NM_BRIDGE_CONN}" &>/dev/null; then
    echo "  Removing existing bridge connection '${NM_BRIDGE_CONN}'..."
    nmcli con down "${NM_BRIDGE_CONN}" 2>/dev/null || true
    nmcli con delete "${NM_BRIDGE_CONN}"
fi

# ── create bridge connection ────────────────────────────────────────────────

echo "Creating bridge connection..."
nmcli con add \
    type bridge \
    ifname "${BRIDGE_NAME}" \
    con-name "${NM_BRIDGE_CONN}" \
    bridge.stp no

nmcli con modify "${NM_BRIDGE_CONN}" \
    connection.zone lan \
    ipv4.method shared \
    ipv4.addresses "${BRIDGE_IP}" \
    ipv6.method ignore \
    connection.autoconnect yes

# ── create WiFi AP as bridge member ────────────────────────────────────────

echo "Adding WiFi AP to bridge..."
nmcli con add \
    type wifi \
    ifname "${AP_IFACE}" \
    con-name "${NM_AP_CONN}" \
    ssid "${SSID}" \
    mode ap \
    master "${BRIDGE_NAME}" \
    slave-type bridge

nmcli con modify "${NM_AP_CONN}" \
    802-11-wireless.band "${BAND}" \
    802-11-wireless.ap-isolation no \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk "${PASSWORD}" \
    connection.autoconnect yes

# ── create wired interface as bridge member ────────────────────────────────

echo "Adding wired interface to bridge..."
nmcli con add \
    type ethernet \
    ifname "${WIRED_IFACE}" \
    con-name "${NM_WIRED_CONN}" \
    master "${BRIDGE_NAME}" \
    slave-type bridge

nmcli con modify "${NM_WIRED_CONN}" \
    connection.autoconnect yes

# ── DHCP range ────────────────────────────────────────────────────────────────
# NM shared mode runs dnsmasq; custom range goes in dnsmasq-shared.d/
# dnsmasq provides DHCP but forwards DNS queries to pihole (port=0 in 10-no-dns.conf)

mkdir -p /etc/NetworkManager/dnsmasq-shared.d
cat > "${SEABIRD_BRIDGE_CONF}" <<EOF
# seabird crew LAN bridge DHCP config — managed by install-crew-bridge.sh, do not edit manually
dhcp-range=${DHCP_START},${DHCP_END},12h
# Tell DHCP clients to use pihole for DNS resolution
dhcp-option=6,${PIHOLE_IP}
EOF
echo "  DHCP range and DNS forwarder configured in ${SEABIRD_BRIDGE_CONF}"

# ── register seabird.local in Pi-hole custom DNS ──────────────────────────────

PIHOLE_CUSTOM_LIST="/srv/seabird/pihole/etc-pihole/custom.list"
if [[ -d /srv/seabird/pihole ]]; then
    mkdir -p /srv/seabird/pihole/etc-pihole
    # Replace or add seabird entry so re-runs stay idempotent
    if grep -q "seabird" "${PIHOLE_CUSTOM_LIST}" 2>/dev/null; then
        sed -i "s/^.* seabird\.local.*$/${BRIDGE_ADDR} seabird.local seabird/" "${PIHOLE_CUSTOM_LIST}"
        echo "  Updated seabird.local DNS entry → ${BRIDGE_ADDR}"
    else
        echo "${BRIDGE_ADDR} seabird.local seabird" >> "${PIHOLE_CUSTOM_LIST}"
        echo "  Added seabird.local DNS entry → ${BRIDGE_ADDR}"
    fi
else
    echo "  Note: /srv/seabird/pihole not mounted yet; run install-services.sh to create dirs,"
    echo "        then re-run install-crew-bridge.sh to write the seabird.local DNS entry."
fi

# ── bring up connections ───────────────────────────────────────────────────────

echo "Activating bridge and members..."
nmcli con up "${NM_BRIDGE_CONN}"
sleep 1
nmcli con up "${NM_AP_CONN}"
nmcli con up "${NM_WIRED_CONN}"

echo
echo "Crew LAN bridge '${SSID}' is active:"
echo "  Bridge interface: ${BRIDGE_NAME} (${BRIDGE_IP})"
echo "  WiFi SSID       : ${SSID} (band: ${BAND})"
echo "  Wired interface : ${WIRED_IFACE}"
echo "  DHCP range      : ${DHCP_START} – ${DHCP_END}"
echo "  DNS server      : ${PIHOLE_IP} (pihole)"
echo "  Gateway address : ${BRIDGE_ADDR}"
