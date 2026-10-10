#!/usr/bin/env bash
# Install the optional Epever monitor without altering controller settings.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEST="/root/.local/lib/epevermon"

if [[ $EUID -ne 0 ]]; then
    echo "run as root" >&2
    exit 1
fi

mkdir -p "${DEST}"
install -m 0644 "${SCRIPT_DIR}/epevermon/"*.py "${DEST}/"
# Reuse the Daly device-access flow without installing its BLE dependencies.
install -m 0644 "${SCRIPT_DIR}/dalymon/signalk_sink.py" "${DEST}/"
if [[ ! -d "${DEST}/.venv" ]]; then
    python3 -m venv "${DEST}/.venv"
fi
"${DEST}/.venv/bin/pip" install -r "${SCRIPT_DIR}/epevermon/requirements.txt"
install -m 0644 "${ROOT_DIR}/config/epevermon/epevermon.conf.example" /etc/epevermon.conf.example
install -m 0644 "${ROOT_DIR}/config/systemd/epevermon.service" /etc/systemd/system/epevermon.service
systemctl daemon-reload

if [[ ! -f /etc/epevermon.conf ]]; then
    echo "epevermon installed; service not enabled until configured"
    echo "Copy /etc/epevermon.conf.example to /etc/epevermon.conf, check the gateway IP,"
    echo "then rerun this installer. InfluxDB is disabled until a bucket/token is configured."
    exit 0
fi

chmod 0600 /etc/epevermon.conf
"${DEST}/.venv/bin/python" "${DEST}/epevermon.py" --config /etc/epevermon.conf --check-config
systemctl enable epevermon.service
systemctl restart epevermon.service
echo "epevermon installed and restarted; approve its device access in Signal K"
