#!/usr/bin/env bash
# install-crew-lan.sh -- configure a standalone wired crew LAN profile
#
# Uses NetworkManager shared mode so the interface serves DHCP/DNS to directly
# connected clients when bridge mode is not in use.
#
# Default interface is the USB-attached crew port (end0), so the onboard
# ethernet (enp4s0) can stay dedicated for upstream WAN use.
#
# Usage:
#   sudo scripts/install-crew-lan.sh
#   sudo scripts/install-crew-lan.sh --iface end0 --ip 192.168.42.1/24

set -euo pipefail

LAN_IFACE="end0"
NM_CONN="seabird-crew-usb-lan"
LAN_IP="192.168.42.1/24"
PIHOLE_IP=""
NM_DNSMASQ_CONF="/etc/NetworkManager/dnsmasq-shared.d/seabird-crew-lan.conf"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iface) LAN_IFACE="$2"; shift 2 ;;
        --ip) LAN_IP="$2"; shift 2 ;;
        --pihole-ip) PIHOLE_IP="$2"; shift 2 ;;
        -h|--help)
            sed -n '/^# install-crew-lan/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) echo "error: unknown option '$1'" >&2; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root" >&2
    exit 1
fi

if ! [[ "${LAN_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    echo "error: invalid IP/prefix format '${LAN_IP}' — expected e.g. 10.42.0.1/24" >&2
    exit 1
fi

if [[ -z "${PIHOLE_IP}" ]]; then
    PIHOLE_IP="${LAN_IP%%/*}"
fi

echo "Configuring wired crew LAN on ${LAN_IFACE} (${LAN_IP})..."

if ! nmcli con show "${NM_CONN}" &>/dev/null; then
    echo "Creating NetworkManager connection '${NM_CONN}' for ${LAN_IFACE}..."
    nmcli con add type ethernet ifname "${LAN_IFACE}" con-name "${NM_CONN}"
fi

nmcli con modify "${NM_CONN}" \
    connection.interface-name "${LAN_IFACE}" \
    connection.autoconnect yes \
    connection.zone lan \
    ipv4.method shared \
    ipv4.addresses "${LAN_IP}" \
    ipv6.method ignore

# NM shared mode runs dnsmasq; advertise Pi-hole as primary DNS with Quad9
# fallback so clients keep resolving if Pi-hole is down.
mkdir -p /etc/NetworkManager/dnsmasq-shared.d
cat > "${NM_DNSMASQ_CONF}" <<EOF
# seabird crew LAN DHCP config — managed by install-crew-lan.sh, do not edit manually
dhcp-option=6,${PIHOLE_IP},9.9.9.9
EOF

nmcli con up "${NM_CONN}"

echo "Wired crew LAN is active on ${LAN_IFACE} (${LAN_IP})"