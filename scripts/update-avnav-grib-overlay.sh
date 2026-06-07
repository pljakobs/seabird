#!/usr/bin/env bash
# Download a GRIB file, convert one band into MBTiles, and update AvNav charts.
# Designed for systemd oneshot execution.
set -euo pipefail

# Source GRIB model (currently NOAA GFS 0.25 deg).
MODEL="${MODEL:-gfs}"
# Forecast step in hours (3 digits for GFS filenames).
FORECAST_HOUR="${FORECAST_HOUR:-003}"

# Geographic crop (lon_min,lat_min,lon_max,lat_max) in EPSG:4326.
# Default: German Baltic Sea region.
BBOX="${BBOX:-8.0,53.0,16.5,60.0}"

# GRIB band to export (1-based GDAL GRIB band index).
# Use `gdalinfo <file.grib2>` to inspect available bands.
BAND_INDEX="${BAND_INDEX:-1}"

MINZOOM="${MINZOOM:-4}"
MAXZOOM="${MAXZOOM:-8}"

CHART_DIR="${CHART_DIR:-/srv/seabird/avnav/charts/weather}"
TARGET_FILE="${TARGET_FILE:-${CHART_DIR}/grib-overlay.mbtiles}"
WORK_DIR="${WORK_DIR:-/var/tmp/seabird-grib}"
MIN_BYTES="${MIN_BYTES:-100000}"

if [[ "${MODEL}" != "gfs" ]]; then
    echo "Unsupported MODEL='${MODEL}'. Supported: gfs" >&2
    exit 1
fi

for cmd in curl file gdalwarp gdal_translate gdalinfo; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "Missing dependency: ${cmd}" >&2
        echo "Install GDAL + curl on the host, then retry." >&2
        exit 1
    fi
done

mkdir -p "${CHART_DIR}" "${WORK_DIR}"

IFS=',' read -r LON_MIN LAT_MIN LON_MAX LAT_MAX <<< "${BBOX}"

find_gfs_url() {
    local base now_epoch age_hours cycle_epoch ymd hh cyc url
    base="https://nomads.ncep.noaa.gov/pub/data/nccf/com/gfs/prod"
    now_epoch="$(date -u +%s)"

    # Try recent 6-hour cycles, newest first.
    for age_hours in $(seq 0 6 48); do
        cycle_epoch="$(( now_epoch - age_hours * 3600 ))"
        ymd="$(date -u -d "@${cycle_epoch}" +%Y%m%d)"
        hh="$(date -u -d "@${cycle_epoch}" +%H)"
        cyc="$(( (10#${hh} / 6) * 6 ))"
        printf -v hh '%02d' "${cyc}"

        url="${base}/gfs.${ymd}/${hh}/atmos/gfs.t${hh}z.pgrb2.0p25.f${FORECAST_HOUR}"
        if curl -fsI --connect-timeout 10 "${url}" >/dev/null; then
            printf '%s\n' "${url}"
            return 0
        fi
    done

    return 1
}

GRIB_URL="$(find_gfs_url)" || {
    echo "Could not resolve a recent GFS GRIB URL." >&2
    exit 1
}

RAW_GRIB="${WORK_DIR}/raw.grib2"
WARP_TIF="${WORK_DIR}/overlay-warped.tif"
TMP_FILE="${TARGET_FILE}.tmp"

echo "Downloading ${GRIB_URL}..."
curl -fL --retry 5 --retry-delay 5 --retry-all-errors \
    --connect-timeout 15 --max-time 1800 \
    -o "${RAW_GRIB}" "${GRIB_URL}"

size_bytes="$(stat -c%s "${RAW_GRIB}")"
if [[ "${size_bytes}" -lt "${MIN_BYTES}" ]]; then
    echo "Downloaded GRIB is too small (${size_bytes} bytes), aborting" >&2
    exit 1
fi

if ! file -b "${RAW_GRIB}" | grep -qi "grib"; then
    echo "Downloaded file is not a GRIB dataset, aborting" >&2
    exit 1
fi

echo "Converting GRIB band ${BAND_INDEX} to WebMercator..."
gdalwarp -overwrite \
    -of GTiff \
    -b "${BAND_INDEX}" \
    -te "${LON_MIN}" "${LAT_MIN}" "${LON_MAX}" "${LAT_MAX}" \
    -te_srs EPSG:4326 \
    -t_srs EPSG:3857 \
    -r bilinear \
    -dstalpha \
    "${RAW_GRIB}" "${WARP_TIF}"

echo "Building MBTiles ${TMP_FILE}..."
gdal_translate \
    -of MBTILES \
    -co TILE_FORMAT=PNG \
    -co MINZOOM="${MINZOOM}" \
    -co MAXZOOM="${MAXZOOM}" \
    "${WARP_TIF}" "${TMP_FILE}"

if [[ ! -s "${TMP_FILE}" ]]; then
    echo "Generated MBTiles is empty, aborting" >&2
    exit 1
fi

if [[ -f "${TARGET_FILE}" ]] && cmp -s "${TARGET_FILE}" "${TMP_FILE}"; then
    echo "GRIB overlay unchanged — nothing to do."
    rm -f "${TMP_FILE}"
    exit 0
fi

mv -f "${TMP_FILE}" "${TARGET_FILE}"
chmod 0644 "${TARGET_FILE}"

echo "Updated ${TARGET_FILE}."
if systemctl is-active --quiet avnav.service; then
    echo "Restarting avnav.service to pick up updated GRIB overlay..."
    systemctl restart avnav.service
fi
