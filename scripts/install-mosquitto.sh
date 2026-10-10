#!/usr/bin/env bash
# Install the optional, anonymous crew-only MQTT broker.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${SCRIPT_DIR}/../config/mosquitto"
DEST="/srv/seabird/mosquitto"

if [[ $EUID -ne 0 ]]; then
    echo "error: run as root" >&2
    exit 1
fi
if ! ip -4 address show | grep -q 'inet 192\.168\.42\.1/'; then
    echo "error: crew address 192.168.42.1 is not configured" >&2
    exit 1
fi
if [[ ! -d /srv/seabird ]]; then
    echo "error: /srv/seabird is missing; configure Seabird storage first" >&2
    exit 1
fi

mkdir -p "${DEST}/config" "${DEST}/data" /etc/containers/systemd
if [[ -f "${DEST}/config/mosquitto.conf" ]] && \
        ! cmp -s "${SOURCE}/mosquitto.conf" "${DEST}/config/mosquitto.conf"; then
    cp -p "${DEST}/config/mosquitto.conf" "${DEST}/config/mosquitto.conf.bak.$(date +%s%N)"
fi
install -m 0644 "${SOURCE}/mosquitto.conf" "${DEST}/config/mosquitto.conf"
install -m 0644 "${SOURCE}/mosquitto.container" /etc/containers/systemd/mosquitto.container
systemctl daemon-reload
# Quadlet's [Install] section provides boot activation; generated units cannot
# be enabled with systemctl enable.
systemctl restart mosquitto.service
systemctl is-active --quiet mosquitto.service
echo "Mosquitto started: 192.168.42.1:1883, anonymous MQTT on the crew address only."
