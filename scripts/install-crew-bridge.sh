#!/usr/bin/env bash
# install-crew-bridge.sh -- configure br-crew bridge for unified crew LAN
#
# Creates a NetworkManager-managed Linux bridge (br-crew) and attaches:
# - crew WiFi AP (wlp6s0)
# - crew wired port (default: end0, USB-attached)
#
# The bridge itself serves DHCP using NetworkManager shared mode.
#
# Usage:
#   sudo scripts/install-crew-bridge.sh
#   sudo scripts/install-crew-bridge.sh --ssid SeaBird --password mysecret --ip 192.168.42.1/24
#
# Options (all are prompted interactively if not provided):
#   --ssid NAME      WiFi network name
#   --password PSK   WPA2 passphrase (min 8 characters)
#   --ip ADDR/PREFIX Bridge IP address and prefix length (default: 192.168.42.1/24)
#   --pihole-ip IP   pihole DNS server IP (default: bridge IP)
#   --band BAND      WiFi band: bg (2.4 GHz) or a (5 GHz, default: bg)
#   --wired-iface IF Crew wired member interface (default: end0)
#
# Safe to re-run.

set -euo pipefail

AP_IFACE="wlp6s0"
WIRED_IFACE="end0"
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
SUCCESS=0

OLD_AP_CONN="$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | awk -F: -v dev="${AP_IFACE}" '$2==dev{print $1; exit}')"
OLD_WIRED_CONN="$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | awk -F: -v dev="${WIRED_IFACE}" '$2==dev{print $1; exit}')"

_rollback_on_error() {
    local rc=$?
    if [[ ${rc} -ne 0 && ${SUCCESS} -eq 0 ]]; then
        echo
        echo "error: bridge setup failed; attempting rollback of previous links..." >&2
        if [[ -n "${OLD_AP_CONN}" ]]; then
            nmcli con up "${OLD_AP_CONN}" 2>/dev/null || true
        fi
        if [[ -n "${OLD_WIRED_CONN}" ]]; then
            nmcli con up "${OLD_WIRED_CONN}" 2>/dev/null || true
        fi
        echo "rollback attempted. verify with: nmcli device status" >&2
    fi
}
trap _rollback_on_error EXIT

# ── argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssid)     SSID="$2";     shift 2 ;;
        --password) PASSWORD="$2"; shift 2 ;;
        --ip)       BRIDGE_IP="$2";    shift 2 ;;
        --pihole-ip) PIHOLE_IP="$2"; shift 2 ;;
        --band)     BAND="$2";     shift 2 ;;
        --wired-iface) WIRED_IFACE="$2"; shift 2 ;;
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
    while true; do
        read -r -p "AP SSID: " SSID
        if [[ -n "${SSID}" ]]; then
            break
        fi
        echo "SSID must not be empty."
    done
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
echo "  Bridge         : ${BRIDGE_NAME}"
echo "  Members        : ${AP_IFACE}, ${WIRED_IFACE}"
echo "  WiFi SSID      : ${SSID}"
echo "  WiFi Band      : ${BAND} ($([ "${BAND}" = "a" ] && echo "5 GHz" || echo "2.4 GHz"))"
echo "  Bridge IP      : ${BRIDGE_IP}"
echo "  DHCP range     : ${DHCP_START} – ${DHCP_END}"
echo "  DNS server     : ${PIHOLE_IP}"
echo

# -- step 1: create NM bridge profile and activate ---------------------------

echo "Step 1: Creating NetworkManager bridge profile..."
if nmcli con show "${NM_BRIDGE_CONN}" &>/dev/null; then
    nmcli con down "${NM_BRIDGE_CONN}" 2>/dev/null || true
    nmcli con delete "${NM_BRIDGE_CONN}" 2>/dev/null || true
fi

nmcli con add \
    type bridge \
    ifname "${BRIDGE_NAME}" \
    con-name "${NM_BRIDGE_CONN}"

nmcli con modify "${NM_BRIDGE_CONN}" \
    connection.zone lan \
    bridge.stp no \
    ipv4.method shared \
    ipv4.addresses "${BRIDGE_IP}" \
    ipv6.method ignore \
    connection.autoconnect yes

nmcli con up "${NM_BRIDGE_CONN}"
sleep 1
echo "  Bridge profile ready."

# -- step 2: configure WiFi AP as bridge member ------------------------------

echo "Step 2: Configuring WiFi AP..."
if nmcli con show "${NM_AP_CONN}" &>/dev/null; then
    nmcli con down "${NM_AP_CONN}" 2>/dev/null || true
    nmcli con delete "${NM_AP_CONN}" 2>/dev/null || true
fi

nmcli con add \
    type wifi \
    ifname "${AP_IFACE}" \
    con-name "${NM_AP_CONN}" \
    ssid "${SSID}" \
    mode ap

nmcli con modify "${NM_AP_CONN}" \
    connection.zone '' \
    connection.master "${NM_BRIDGE_CONN}" \
    connection.slave-type bridge \
    802-11-wireless.band "${BAND}" \
    802-11-wireless.ap-isolation no \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk "${PASSWORD}" \
    ipv4.method disabled \
    ipv6.method ignore \
    connection.autoconnect yes

nmcli con up "${NM_AP_CONN}" 2>/dev/null || true
sleep 1
echo "  WiFi AP ready."

# -- step 3: configure wired bridge member -----------------------------------

echo "Step 3: Configuring wired interface..."
if nmcli con show "${NM_WIRED_CONN}" &>/dev/null; then
    nmcli con down "${NM_WIRED_CONN}" 2>/dev/null || true
    nmcli con delete "${NM_WIRED_CONN}" 2>/dev/null || true
fi

nmcli con add \
    type ethernet \
    ifname "${WIRED_IFACE}" \
    con-name "${NM_WIRED_CONN}"

nmcli con modify "${NM_WIRED_CONN}" \
    connection.zone '' \
    connection.master "${NM_BRIDGE_CONN}" \
    connection.slave-type bridge \
    ipv4.method disabled \
    ipv6.method ignore \
    connection.autoconnect yes

nmcli con up "${NM_WIRED_CONN}" 2>/dev/null || true
sleep 1
echo "  Wired interface ready."

# -- step 4: configure DHCP and DNS ------------------------------------------

echo "Step 4: Configuring DHCP range and DNS..."
mkdir -p /etc/NetworkManager/dnsmasq-shared.d
rm -f /etc/NetworkManager/dnsmasq-shared.d/seabird-crew-lan.conf
rm -f /etc/NetworkManager/dnsmasq-shared.d/seabird-ap.conf
cat > "${SEABIRD_BRIDGE_CONF}" <<EOF
# seabird crew LAN bridge DHCP config — managed by install-crew-bridge.sh, do not edit manually
dhcp-range=${DHCP_START},${DHCP_END},12h
# Tell DHCP clients to use Pi-hole first, with Quad9 as fallback
dhcp-option=6,${PIHOLE_IP},9.9.9.9
EOF
echo "  DHCP and DNS configured."

# -- step 5: allow cockpit from crew LAN -------------------------------------

echo "Step 5: Ensuring Cockpit is reachable from crew LAN..."
firewall-cmd --zone=lan --add-service=cockpit --permanent >/dev/null 2>&1 || true
firewall-cmd --reload >/dev/null 2>&1 || true
echo "  Cockpit service added to lan zone."

# -- step 6: register seabird.local in Pi-hole custom DNS --------------------

echo "Step 6: Registering seabird.local in Pi-hole..."
PIHOLE_CUSTOM_LIST="/srv/seabird/pihole/etc-pihole/custom.list"
if [[ -d /srv/seabird/pihole ]]; then
    mkdir -p /srv/seabird/pihole/etc-pihole
    if grep -q "seabird" "${PIHOLE_CUSTOM_LIST}" 2>/dev/null; then
        sed -i "s/^.* seabird\.local.*$/${BRIDGE_ADDR} seabird.local seabird/" "${PIHOLE_CUSTOM_LIST}"
        echo "  Updated seabird.local DNS entry → ${BRIDGE_ADDR}"
    else
        echo "${BRIDGE_ADDR} seabird.local seabird" >> "${PIHOLE_CUSTOM_LIST}"
        echo "  Added seabird.local DNS entry → ${BRIDGE_ADDR}"
    fi
else
    echo "  Note: /srv/seabird/pihole not yet; skipping seabird.local entry."
fi

# -- step 7: legacy profile cleanup (safe) -----------------------------------

echo "Step 7: Cleaning legacy profiles (safe mode)..."
for old_conn in "Wired connection 2" "Wired connection 1"; do
    if nmcli con show "${old_conn}" &>/dev/null; then
        nmcli con modify "${old_conn}" connection.autoconnect no 2>/dev/null || true
        echo "  Left '${old_conn}' in place as fallback (autoconnect disabled)."
    fi
done

echo
echo "✓ Crew LAN bridge is ready:"
echo "  Bridge interface: ${BRIDGE_NAME}"
echo "  Bridge IP        : ${BRIDGE_IP}"
echo "  WiFi SSID        : ${SSID}"
echo "  Wired interface  : ${WIRED_IFACE}"
echo "  DHCP range       : ${DHCP_START} – ${DHCP_END}"
echo "  DNS server       : ${PIHOLE_IP}"
echo
echo "Verify connectivity with: nmcli -f NAME,DEVICE,TYPE,STATE con show --active"
SUCCESS=1
