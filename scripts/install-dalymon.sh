#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DALY_SRC="${SCRIPT_DIR}/dalymon"
DALY_DST="/root/.local/lib/dalymon"
SYSTEMD_SRC="${ROOT_DIR}/config/systemd"
CONFIG_EXAMPLE="${ROOT_DIR}/config/dalymon/dalymon.conf.example"

if [[ $EUID -ne 0 ]]; then
    echo "run as root" >&2
    exit 1
fi

mkdir -p "${DALY_DST}"
install -m 0644 "${DALY_SRC}/"*.py "${DALY_DST}/"

if [[ ! -d "${DALY_DST}/.venv" ]]; then
    python3 -m venv "${DALY_DST}/.venv"
fi
"${DALY_DST}/.venv/bin/pip" install -r "${DALY_SRC}/requirements.txt"

if [[ ! -f /etc/dalymon.conf.example ]]; then
    install -m 0644 "${CONFIG_EXAMPLE}" /etc/dalymon.conf.example
fi

install -m 0644 "${SYSTEMD_SRC}/dalymon.service" /etc/systemd/system/dalymon.service
mkdir -p /etc/systemd/system/dalymon.service.d
install -m 0644 "${SYSTEMD_SRC}/dalymon.service.d/override.conf" /etc/systemd/system/dalymon.service.d/override.conf

systemctl daemon-reload

if [[ ! -f /etc/dalymon.conf ]]; then
    echo "dalymon code and unit installed; service remains disabled until configured"
    echo "copy /etc/dalymon.conf.example to /etc/dalymon.conf, set the InfluxDB token,"
    echo "then run scripts/install-dalymon.sh again to enable and start the service"
    exit 0
fi

if grep -qE 'REPLACE_WITH_|11:22:33:44:55:66' /etc/dalymon.conf; then
    echo "/etc/dalymon.conf still contains example values; edit it before enabling dalymon" >&2
    exit 1
fi

"${DALY_DST}/.venv/bin/python" -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' /etc/dalymon.conf
chmod 0600 /etc/dalymon.conf
systemctl enable dalymon.service
systemctl restart dalymon.service

echo "dalymon installed and restarted"
