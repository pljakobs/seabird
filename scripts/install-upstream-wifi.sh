#!/usr/bin/env bash
# install-upstream-wifi.sh -- bind upstream WiFi client profiles to the onboard card
#
# The boat has two WiFi radios whose kernel names can swap between boots:
#   - Intel iwlwifi (wlp6s0)  → crew access point "Antares"
#   - CM4 onboard brcmfmac    → upstream client (marina / harbour WiFi)
#
# Because the onboard card gets a non-deterministic wlanN name, client profiles
# bound to a fixed name (e.g. wlan0) silently fail to activate, and name-less
# profiles can land on the AP radio and block the crew AP. This script pins all
# infrastructure-mode (client) WiFi profiles to the upstream card by its
# PERMANENT MAC and clears any stale interface-name binding, so upstream WiFi
# always uses the onboard radio and never steals the AP card.
#
# It can also add/update a single upstream network.
#
# Usage:
#   sudo scripts/install-upstream-wifi.sh                 # re-pin existing profiles
#   sudo scripts/install-upstream-wifi.sh --iface wlan1   # force upstream interface
#   sudo scripts/install-upstream-wifi.sh --mac e4:5f:01:65:e6:13
#   sudo scripts/install-upstream-wifi.sh --add-ssid "Marina-Gast"            # open
#   sudo scripts/install-upstream-wifi.sh --add-ssid "Marina" --add-password secret
#
# Options:
#   --iface IF        Upstream WiFi interface (default: auto-detect onboard card)
#   --mac MAC         Upstream card permanent MAC (default: derived from --iface)
#   --ap-iface IF     Crew AP interface to exclude from upstream (default: wlp6s0)
#   --add-ssid NAME   Create/update an upstream network profile for NAME
#   --add-password P  WPA2 passphrase for --add-ssid (omit for an open network)
#   --priority N      autoconnect-priority for --add-ssid profile (default: 0)
#
# Safe to re-run.

set -euo pipefail

UPSTREAM_IFACE=""
UPSTREAM_MAC=""
AP_IFACE="wlp6s0"
ADD_SSID=""
ADD_PASSWORD=""
ADD_PRIORITY="0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iface)        UPSTREAM_IFACE="$2"; shift 2 ;;
        --mac)          UPSTREAM_MAC="$2";   shift 2 ;;
        --ap-iface)     AP_IFACE="$2";       shift 2 ;;
        --add-ssid)     ADD_SSID="$2";       shift 2 ;;
        --add-password) ADD_PASSWORD="$2";   shift 2 ;;
        --priority)     ADD_PRIORITY="$2";   shift 2 ;;
        -h|--help)
            sed -n '/^# install-upstream-wifi/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) echo "error: unknown option '$1'" >&2; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root" >&2
    exit 1
fi

# Permanent MAC of an interface (survives MAC randomization / cloned MACs).
perm_mac() {
    local iface="$1" mac
    mac="$(ethtool -P "${iface}" 2>/dev/null | awk '{print $NF}')"
    if ! [[ "${mac}" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || [[ "${mac}" == "00:00:00:00:00:00" ]]; then
        mac="$(cat "/sys/class/net/${iface}/address" 2>/dev/null || true)"
    fi
    echo "${mac}"
}

# Auto-detect the upstream (onboard) WiFi interface: any WiFi device that is not
# the AP card. Prefer the brcmfmac (CM4 onboard) driver when several exist.
detect_upstream_iface() {
    local dev driver best=""
    while IFS=: read -r dev dtype _; do
        [[ "${dtype}" == "wifi" ]] || continue
        [[ "${dev}" == "${AP_IFACE}" ]] && continue
        [[ "${dev}" == p2p-* ]] && continue
        driver="$(basename "$(readlink -f "/sys/class/net/${dev}/device/driver" 2>/dev/null)" 2>/dev/null || true)"
        if [[ "${driver}" == "brcmfmac" ]]; then
            echo "${dev}"; return 0
        fi
        [[ -z "${best}" ]] && best="${dev}"
    done < <(nmcli -t -f DEVICE,TYPE device status)
    echo "${best}"
}

if [[ -z "${UPSTREAM_IFACE}" ]]; then
    UPSTREAM_IFACE="$(detect_upstream_iface)"
fi

if [[ -z "${UPSTREAM_IFACE}" ]]; then
    echo "error: could not detect an upstream WiFi interface (AP card: ${AP_IFACE})." >&2
    echo "       pass --iface IF or --mac MAC explicitly." >&2
    exit 1
fi

if [[ -z "${UPSTREAM_MAC}" ]]; then
    UPSTREAM_MAC="$(perm_mac "${UPSTREAM_IFACE}")"
fi

if ! [[ "${UPSTREAM_MAC}" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
    echo "error: could not determine a valid permanent MAC for ${UPSTREAM_IFACE} (got '${UPSTREAM_MAC}')." >&2
    echo "       pass --mac MAC explicitly." >&2
    exit 1
fi

echo "Upstream WiFi card : ${UPSTREAM_IFACE} (${UPSTREAM_MAC})"
echo "Crew AP card       : ${AP_IFACE} (excluded)"
echo

# -- pin all infrastructure-mode WiFi profiles to the upstream card ----------

pinned=0
while IFS=: read -r name _; do
    [[ -z "${name}" ]] && continue
    mode="$(nmcli -g 802-11-wireless.mode con show "${name}" 2>/dev/null || true)"
    # Only client profiles; never touch the AP profile.
    [[ "${mode}" == "ap" ]] && continue
    nmcli con modify "${name}" \
        802-11-wireless.mac-address "${UPSTREAM_MAC}" \
        connection.interface-name ""
    echo "  pinned '${name}' -> ${UPSTREAM_MAC} (interface-name cleared)"
    pinned=$((pinned + 1))
done < <(nmcli -t -f NAME,TYPE con show | awk -F: '$2=="802-11-wireless"{print $1}')

echo "  ${pinned} upstream WiFi profile(s) pinned."

# -- optionally add/update a specific upstream network -----------------------

if [[ -n "${ADD_SSID}" ]]; then
    echo
    echo "Configuring upstream network '${ADD_SSID}'..."
    if ! nmcli con show "${ADD_SSID}" &>/dev/null; then
        nmcli con add type wifi ifname "*" con-name "${ADD_SSID}" ssid "${ADD_SSID}"
    fi
    nmcli con modify "${ADD_SSID}" \
        802-11-wireless.mode infrastructure \
        802-11-wireless.mac-address "${UPSTREAM_MAC}" \
        connection.interface-name "" \
        connection.autoconnect yes \
        connection.autoconnect-priority "${ADD_PRIORITY}" \
        ipv4.method auto \
        ipv6.method auto
    if [[ -n "${ADD_PASSWORD}" ]]; then
        nmcli con modify "${ADD_SSID}" \
            802-11-wireless-security.key-mgmt wpa-psk \
            802-11-wireless-security.psk "${ADD_PASSWORD}"
    else
        nmcli con modify "${ADD_SSID}" 802-11-wireless-security.key-mgmt "" 2>/dev/null || true
    fi
    echo "  '${ADD_SSID}' ready (priority ${ADD_PRIORITY})."
fi

echo
echo "✓ Upstream WiFi profiles bound to ${UPSTREAM_IFACE} (${UPSTREAM_MAC})."
echo "Verify with: nmcli -f NAME,TYPE,AUTOCONNECT-PRIORITY con show | grep wireless"
