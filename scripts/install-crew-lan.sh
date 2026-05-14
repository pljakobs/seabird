#!/usr/bin/env bash
# install-crew-lan.sh — configure enp4s0 as the wired crew LAN
#
# Uses NetworkManager shared mode so the interface serves DHCP/DNS to directly
# connected clients, matching the WiFi AP's LAN role.
#
# Usage:
#   sudo scripts/install-crew-lan.sh
#   sudo scripts/install-crew-lan.sh --ip 10.42.0.1/24

set -euo pipefail

LAN_IFACE="enp4s0"
NM_CONN="Wired connection 2"
LAN_IP="10.42.0.1/24"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip) LAN_IP="$2"; shift 2 ;;
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

nmcli con up "${NM_CONN}"

echo "Wired crew LAN is active on ${LAN_IFACE} (${LAN_IP})"