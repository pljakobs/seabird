#!/usr/bin/env bash
# Download latest FreeNauticalChart DE mbtiles and keep AvNav charts updated.
# Designed for systemd oneshot execution.
set -euo pipefail

FNC_URL="${FNC_URL:-https://freenauticalchart.net/download/fnc-de.mbtiles}"
CHART_DIR="${CHART_DIR:-/srv/seabird/avnav/charts/fnc}"
TARGET_FILE="${TARGET_FILE:-${CHART_DIR}/fnc-de.mbtiles}"
TMP_FILE="${TARGET_FILE}.tmp"
MIN_BYTES="${MIN_BYTES:-50000000}"

mkdir -p "${CHART_DIR}"

echo "Downloading ${FNC_URL}..."
curl -fL --retry 5 --retry-delay 5 --retry-all-errors \
    --connect-timeout 15 --max-time 3600 \
    -o "${TMP_FILE}" "${FNC_URL}"

size_bytes="$(stat -c%s "${TMP_FILE}")"
if [[ "${size_bytes}" -lt "${MIN_BYTES}" ]]; then
    echo "downloaded file is too small (${size_bytes} bytes), aborting" >&2
    rm -f "${TMP_FILE}"
    exit 1
fi

if ! file -b "${TMP_FILE}" | grep -qi "sqlite"; then
    echo "downloaded file is not an SQLite/mbtiles database, aborting" >&2
    rm -f "${TMP_FILE}"
    exit 1
fi

if [[ -f "${TARGET_FILE}" ]] && cmp -s "${TARGET_FILE}" "${TMP_FILE}"; then
    echo "Chart unchanged — nothing to do."
    rm -f "${TMP_FILE}"
    exit 0
fi

mv -f "${TMP_FILE}" "${TARGET_FILE}"
chmod 0644 "${TARGET_FILE}"

echo "Updated ${TARGET_FILE}."
if systemctl is-active --quiet avnav.service; then
    echo "Restarting avnav.service to pick up updated chart layer..."
    systemctl restart avnav.service
fi
