#!/usr/bin/env bash
# Download weather model products, render multiple overlays to MBTiles,
# and update AvNav charts. Designed for systemd oneshot execution.
set -euo pipefail

MODEL="${MODEL:-icon-d2}"
FORECAST_HOUR="${FORECAST_HOUR:-003}"
WAVE_MODEL="${WAVE_MODEL:-ewam}"
WAVE_FORECAST_HOUR="${WAVE_FORECAST_HOUR:-003}"

# DMI forecast API — GRIBs served from public S3; no API key needed for downloads.
# Collections: dkss_nsbs (ocean currents), wam_nsb (wave model).
# API key (free from https://dmiapi.govcloud.dk/) only needed for the items
# discovery endpoint if you want to query it. Leave empty for unauthenticated
# queries (still works for public collections).
DMI_API_KEY="${DMI_API_KEY:-}"
LAYERS="${LAYERS:-wind_style,wave_style,current_style}"

# lon_min,lat_min,lon_max,lat_max in EPSG:4326
BBOX="${BBOX:-8.0,53.0,16.5,60.0}"
MINZOOM="${MINZOOM:-9}"
MAXZOOM="${MAXZOOM:-12}"
ZOOM_MIN_LIMIT="${ZOOM_MIN_LIMIT:-6}"
ZOOM_MAX_LIMIT="${ZOOM_MAX_LIMIT:-12}"
OVERZOOM_MAX_EXTRA_LEVELS="${OVERZOOM_MAX_EXTRA_LEVELS:-2}"
# Forecast hours to render for each ICON-D2 run (1-hourly, up to +48 h).
# Disk usage is ~1-30 MB per layer per hour; 1 TB NVMe is plenty.
# Override with a custom comma-separated list, e.g. 003,006,012 for lighter runs.
FORECAST_HOURS="${FORECAST_HOURS:-$(seq -f '%03.0f' 1 48 | paste -sd,)}"
# How many model runs to keep on disk (current + N-1 previous).
KEEP_RUNS="${KEEP_RUNS:-2}"

# Set by the main loop for each forecast hour; render functions append it to
# their output filenames so every hour gets a distinct MBTiles file.
WEATHER_SUFFIX=""

WIND_BARB_STEP="${WIND_BARB_STEP:-40}"
WIND_BARB_RENDER_SCALE="${WIND_BARB_RENDER_SCALE:-1}"
# Barbs are rendered natively for zoom levels MINZOOM..WIND_BARB_RENDER_ZOOM_MAX.
# Zoom 10 and 11 use black-outline only; zoom >= WIND_BARB_WHITE_INFILL_MIN_ZOOM
# also adds a white infill pass for contrast at high zoom.
# Strip rendering keeps peak RSS within WIND_BARB_STRIP_MB on Pi CM4.
# z12 needs ~400 MB per strip; on a Pi CM4 (2.8 GB / 1.3 GB free) it OOMs
# when cumulated with z9-z11.  Default to z11; set to 12 on machines with >=4 GB.
WIND_BARB_RENDER_ZOOM_MAX="${WIND_BARB_RENDER_ZOOM_MAX:-11}"
WIND_BARB_WHITE_INFILL_MIN_ZOOM="${WIND_BARB_WHITE_INFILL_MIN_ZOOM:-12}"
WIND_BARB_STRIP_MB="${WIND_BARB_STRIP_MB:-400}"
# Parallel workers for wind barb / current arrow rendering (one per zoom level).
# On Pi CM4 (2.8 GB) 3 workers × 400 MB strip budget fits comfortably.
WIND_BARB_WORKERS="${WIND_BARB_WORKERS:-3}"
# Max layers (wind/wave/current) to render simultaneously per forecast hour.
# Set to "auto" (default) to size by CPU + MemAvailable and requested layer count.
# On Pi CM4 this typically resolves to 2-3, on bigger hosts it can go higher.
LAYER_PARALLEL_WORKERS="${LAYER_PARALLEL_WORKERS:-auto}"
# Boat position for nearest-first strip rendering. Leave empty to auto-fetch
# from AvNav (tried at localhost:8082/api/gps). Falls back to BBOX centre.
BOAT_LAT="${BOAT_LAT:-}"
BOAT_LON="${BOAT_LON:-}"

# Ocean current arrows — requires Copernicus Marine (CMEMS) credentials.
# Register free at https://marine.copernicus.eu/ then set these env vars.
CURRENT_BARB_STEP="${CURRENT_BARB_STEP:-40}"
CURRENT_ARROW_SCALE="${CURRENT_ARROW_SCALE:-1}"
CMEMS_USERNAME="${CMEMS_USERNAME:-}"
CMEMS_PASSWORD="${CMEMS_PASSWORD:-}"
# NW European Shelf hourly surface currents (uo, vo at ~3 km).
CMEMS_DATASET="${CMEMS_DATASET:-cmems_mod_nws_phy-cur_anfc_0.027deg_PT1H-i}"

# MBTiles must live at the top level of AvNav's chart directory — the scanner
# does not recurse into subdirectories.
CHART_DIR="${CHART_DIR:-/srv/seabird/avnav/charts}"
WEATHER_PREFIX="${WEATHER_PREFIX:-weather-}"
WORK_DIR="${WORK_DIR:-/var/tmp/seabird-grib}"
MIN_BYTES="${MIN_BYTES:-50000}"
MIN_BYTES_ICON="${MIN_BYTES_ICON:-${MIN_BYTES}}"
MIN_BYTES_WAVE="${MIN_BYTES_WAVE:-${MIN_BYTES}}"

if [[ "${MODEL}" != "icon-d2" ]]; then
    echo "Unsupported MODEL='${MODEL}'. Supported: icon-d2" >&2
    exit 1
fi
if [[ "${WAVE_MODEL}" != "ewam" && "${WAVE_MODEL}" != "dmi" ]]; then
    echo "Unsupported WAVE_MODEL='${WAVE_MODEL}'. Supported: ewam, dmi" >&2
    exit 1
fi

for cmd in curl file gdalwarp gdal_translate gdalinfo bunzip2 python3; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "Missing dependency: ${cmd}" >&2
        echo "Install GDAL and curl on the host, then retry." >&2
        exit 1
    fi
done

mkdir -p "${CHART_DIR}" "${WORK_DIR}"
IFS=',' read -r LON_MIN LAT_MIN LON_MAX LAT_MAX <<< "${BBOX}"

if [[ ! "${MINZOOM}" =~ ^[0-9]+$ ]]; then
    echo "MINZOOM must be an integer, got '${MINZOOM}'" >&2
    exit 1
fi
if [[ ! "${MAXZOOM}" =~ ^[0-9]+$ ]]; then
    echo "MAXZOOM must be an integer, got '${MAXZOOM}'" >&2
    exit 1
fi
if [[ ! "${ZOOM_MIN_LIMIT}" =~ ^[0-9]+$ ]]; then
    echo "ZOOM_MIN_LIMIT must be an integer, got '${ZOOM_MIN_LIMIT}'" >&2
    exit 1
fi
if [[ ! "${ZOOM_MAX_LIMIT}" =~ ^[0-9]+$ ]]; then
    echo "ZOOM_MAX_LIMIT must be an integer, got '${ZOOM_MAX_LIMIT}'" >&2
    exit 1
fi
if [[ ! "${OVERZOOM_MAX_EXTRA_LEVELS}" =~ ^[0-9]+$ ]]; then
    echo "OVERZOOM_MAX_EXTRA_LEVELS must be a non-negative integer, got '${OVERZOOM_MAX_EXTRA_LEVELS}'" >&2
    exit 1
fi
if [[ ! "${WIND_BARB_RENDER_SCALE}" =~ ^[0-9]+$ ]] || (( 10#${WIND_BARB_RENDER_SCALE} < 1 )); then
    echo "WIND_BARB_RENDER_SCALE must be an integer >= 1, got '${WIND_BARB_RENDER_SCALE}'" >&2
    exit 1
fi

min_zoom="$((10#${MINZOOM}))"
max_zoom="$((10#${MAXZOOM}))"
min_limit="$((10#${ZOOM_MIN_LIMIT}))"
max_limit="$((10#${ZOOM_MAX_LIMIT}))"

if (( min_limit > max_limit )); then
    echo "Invalid zoom limits: ZOOM_MIN_LIMIT (${min_limit}) > ZOOM_MAX_LIMIT (${max_limit})" >&2
    exit 1
fi

if (( min_zoom < min_limit )); then
    echo "MINZOOM=${min_zoom} is below supported limit ${min_limit}; clamping." >&2
    min_zoom="${min_limit}"
fi
if (( max_zoom > max_limit )); then
    echo "MAXZOOM=${max_zoom} is above supported limit ${max_limit}; clamping." >&2
    max_zoom="${max_limit}"
fi
if (( max_zoom < min_zoom )); then
    echo "MAXZOOM=${max_zoom} is below MINZOOM=${min_zoom}; using MINZOOM for both." >&2
    max_zoom="${min_zoom}"
fi

MINZOOM="${min_zoom}"
MAXZOOM="${max_zoom}"

find_recent_icon_cycle() {
    local base now_epoch age_hours cycle_epoch ymd hh cyc cycle url
    base="https://opendata.dwd.de/weather/nwp/icon-d2/grib"
    now_epoch="$(date -u +%s)"

    for age_hours in $(seq 0 3 24); do
        cycle_epoch="$(( now_epoch - age_hours * 3600 ))"
        ymd="$(date -u -d "@${cycle_epoch}" +%Y%m%d)"
        hh="$(date -u -d "@${cycle_epoch}" +%H)"
        cyc="$(( (10#${hh} / 3) * 3 ))"
        printf -v cycle '%02d' "${cyc}"

        url="${base}/${cycle}/t_2m/icon-d2_germany_regular-lat-lon_single-level_${ymd}${cycle}_${FORECAST_HOUR}_2d_t_2m.grib2.bz2"
        if curl -fsI --connect-timeout 10 "${url}" >/dev/null; then
            printf '%s %s\n' "${ymd}" "${cycle}"
            return 0
        fi
    done
    return 1
}

find_recent_ewam_cycle() {
    local base now_epoch age_hours cycle_epoch ymd hh cyc cycle url
    base="https://opendata.dwd.de/weather/maritime/wave_models/ewam/grib"
    now_epoch="$(date -u +%s)"

    for age_hours in $(seq 0 12 72); do
        cycle_epoch="$(( now_epoch - age_hours * 3600 ))"
        ymd="$(date -u -d "@${cycle_epoch}" +%Y%m%d)"
        hh="$(date -u -d "@${cycle_epoch}" +%H)"
        cyc="$(( (10#${hh} / 12) * 12 ))"
        printf -v cycle '%02d' "${cyc}"

        url="${base}/${cycle}/swh/EWAM_SWH_${ymd}${cycle}_${WAVE_FORECAST_HOUR}.grib2.bz2"
        if curl -fsI --connect-timeout 10 "${url}" >/dev/null; then
            printf '%s %s\n' "${ymd}" "${cycle}"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# DMI forecast data helpers (DKSS currents + WAM waves via public S3)
# ---------------------------------------------------------------------------

# Query DMI items endpoint to find the most recent model run for a collection.
# Prints "YYYYMMDD HH" (UTC) on success, returns 1 on failure.
find_recent_dmi_cycle() {
    local collection="$1"
    local api_key_param=""
    [[ -n "${DMI_API_KEY:-}" ]] && api_key_param="?api-key=${DMI_API_KEY}"
    local items_url="https://dmigw.govcloud.dk/v1/forecastdata/collections/${collection}/items${api_key_param:+${api_key_param}&}limit=20"
    [[ -z "${api_key_param}" ]] && items_url="https://dmigw.govcloud.dk/v1/forecastdata/collections/${collection}/items?limit=20"

    local result
    result=$(curl -fsL --connect-timeout 15 --max-time 30 "${items_url}" 2>/dev/null | \
        python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    runs = [f['properties']['modelRun'] for f in d.get('features', [])
            if f.get('properties', {}).get('modelRun')]
    latest = sorted(set(runs))[-1] if runs else ''
    if latest:
        from datetime import datetime, timezone
        dt = datetime.strptime(latest, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
        print(dt.strftime('%Y%m%d'), dt.strftime('%H'))
except Exception:
    pass
" 2>/dev/null)
    [[ -z "${result}" ]] && return 1
    echo "${result}"
}

find_recent_dmi_dkss_cycle() { find_recent_dmi_cycle "dkss_nsbs"; }
find_recent_dmi_wam_cycle()  { find_recent_dmi_cycle "wam_nsb"; }

# Wait for a list of background jobs and return non-zero if any failed.
wait_for_jobs_or_fail() {
    local pid rc=0
    for pid in "$@"; do
        if ! wait "${pid}"; then
            rc=1
        fi
    done
    return "${rc}"
}

# Download a GRIB from DMI public S3 (no credentials needed).
# Usage: download_dmi_grib URL DEST
# Returns 1 if download failed or GDAL cannot read the result.
download_dmi_grib() {
    local url="$1"
    local dest="$2"

    echo "Downloading DMI GRIB: ${url}..."
    curl -fL --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 300 \
        -o "${dest}" "${url}" 2>/dev/null

    if [[ ! -s "${dest}" ]]; then
        echo "DMI download produced empty file: ${url}" >&2
        rm -f "${dest}"
        return 1
    fi

    if ! gdalinfo "${dest}" >/dev/null 2>&1; then
        echo "DMI file not readable by GDAL: ${url}" >&2
        rm -f "${dest}"
        return 1
    fi
    return 0
}

# Format a YYYYMMDD + HH pair as a DMI filename timestamp (e.g. 2026-06-13T000000Z).
_dmi_fmt_time() {
    local ymd="$1"   # YYYYMMDD
    local hh="$2"    # HH
    printf '%s-%s-%sT%s0000Z' "${ymd:0:4}" "${ymd:4:2}" "${ymd:6:2}" "${hh}"
}

# Try to determine boat GPS position from AvNav REST API.
# Sets BOAT_LAT / BOAT_LON; falls back to the centre of BBOX.
fetch_boat_position() {
    [[ -n "${BOAT_LAT:-}" && -n "${BOAT_LON:-}" ]] && return 0
    local pos lat lon _url
    for _url in "http://127.0.0.1:8082/api/gps" "http://localhost:8082/api/gps"; do
        pos=$(curl -fsS --connect-timeout 3 --max-time 5 "${_url}" 2>/dev/null) || continue
        lat=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); v=d.get('lat'); print('' if v is None else v)" <<< "${pos}" 2>/dev/null) || continue
        lon=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); v=d.get('lon'); print('' if v is None else v)" <<< "${pos}" 2>/dev/null) || continue
        if [[ -n "${lat}" && "${lat}" != "None" ]]; then
            BOAT_LAT="${lat}"
            BOAT_LON="${lon}"
            echo "Boat position from AvNav: ${BOAT_LAT}\u00b0N ${BOAT_LON}\u00b0E"
            return 0
        fi
    done
    BOAT_LAT=$(python3 -c "print(round((${LAT_MIN} + ${LAT_MAX}) / 2.0, 4))")
    BOAT_LON=$(python3 -c "print(round((${LON_MIN} + ${LON_MAX}) / 2.0, 4))")
    echo "Tile priority: BBOX centre ${BOAT_LAT}\u00b0N ${BOAT_LON}\u00b0E" >&2
}

# Render DMI WAM North Sea+Baltic waves (SWH + direction) for the current
# FORECAST_HOUR into wave-height and wave-direction MBTiles.
render_dmi_wave_style() {
    local wave_date="$1"
    local wave_cycle="$2"

    local run_fmt valid_time_fmt s3_url fh_int
    run_fmt="$(_dmi_fmt_time "${wave_date}" "${wave_cycle}")"
    fh_int="$(( 10#${FORECAST_HOUR} ))"
    valid_time_fmt=$(python3 -c "
from datetime import datetime, timedelta, timezone
run = datetime.strptime('${wave_date}${wave_cycle}', '%Y%m%d%H').replace(tzinfo=timezone.utc)
valid = run + timedelta(hours=${fh_int})
print(valid.strftime('%Y-%m-%dT%H%M%SZ'))
")

    s3_url="https://dmi-opendata.s3.eu-north-1.amazonaws.com/forecastdata/WAM_NSB_SF/WAM_NSB_SF_${run_fmt}_${valid_time_fmt}.grib"

    local raw="${WORK_DIR}/wam-nsb.grib"
    local swh_band="${WORK_DIR}/wam-swh.b3.tif"
    local mwd_band="${WORK_DIR}/wam-mwd.b7.tif"
    local swh_warped="${WORK_DIR}/wam-swh.warp.tif"
    local mwd_warped="${WORK_DIR}/wam-mwd.warp.tif"
    local height_target="${CHART_DIR}/${WEATHER_PREFIX}wave-height${WEATHER_SUFFIX}.mbtiles"
    local dir_target="${CHART_DIR}/${WEATHER_PREFIX}wave-direction${WEATHER_SUFFIX}.mbtiles"
    local updated=0

    if ! download_dmi_grib "${s3_url}" "${raw}"; then
        echo "DMI WAM download failed for +${FORECAST_HOUR}h, skipping wave tiles." >&2
        return 1
    fi

    # Band 3 = SWH (ECMWF param 229), Band 7 = MWD (param 230, direction FROM)
    gdal_translate -q -of GTiff -b 3 "${raw}" "${swh_band}" 2>/dev/null &
    local p_swh=$!
    gdal_translate -q -of GTiff -b 7 "${raw}" "${mwd_band}" 2>/dev/null &
    local p_mwd=$!
    if ! wait_for_jobs_or_fail "${p_swh}" "${p_mwd}"; then
        echo "Failed to extract SWH/MWD bands from DMI WAM GRIB." >&2
        rm -f "${raw}" "${swh_band}" "${mwd_band}"
        return 1
    fi
    rm -f "${raw}"
    warp_grib "${swh_band}" "${swh_warped}" &
    local p_warp_swh=$!
    warp_grib "${mwd_band}" "${mwd_warped}" &
    local p_warp_mwd=$!
    if ! wait_for_jobs_or_fail "${p_warp_swh}" "${p_warp_mwd}"; then
        echo "Failed to warp DMI WAM bands." >&2
        rm -f "${swh_band}" "${mwd_band}" "${swh_warped}" "${mwd_warped}"
        return 1
    fi
    rm -f "${swh_band}" "${mwd_band}"

    if build_mbtiles "${swh_warped}" "${height_target}"; then updated=1; fi
    if build_wave_arrows "${swh_warped}" "${mwd_warped}" "${dir_target}"; then updated=1; fi

    rm -f "${swh_warped}" "${mwd_warped}"
    [[ "${updated}" -eq 1 ]] && return 0 || return 1
}

# Render DMI DKSS North Sea+Baltic ocean currents for the current FORECAST_HOUR
# into current-arrows MBTiles.
render_dmi_current_style() {
    local dkss_date="$1"
    local dkss_cycle="$2"

    local run_fmt valid_time_fmt s3_url fh_int
    run_fmt="$(_dmi_fmt_time "${dkss_date}" "${dkss_cycle}")"
    fh_int="$(( 10#${FORECAST_HOUR} ))"
    valid_time_fmt=$(python3 -c "
from datetime import datetime, timedelta, timezone
run = datetime.strptime('${dkss_date}${dkss_cycle}', '%Y%m%d%H').replace(tzinfo=timezone.utc)
valid = run + timedelta(hours=${fh_int})
print(valid.strftime('%Y-%m-%dT%H%M%SZ'))
")

    s3_url="https://dmi-opendata.s3.eu-north-1.amazonaws.com/forecastdata/DKSS_NSBS_SF/DKSS_NSBS_SF_${run_fmt}_${valid_time_fmt}.grib"

    local raw="${WORK_DIR}/dkss-nsbs.grib"
    local u_band="${WORK_DIR}/dkss-u.b4.tif"
    local v_band="${WORK_DIR}/dkss-v.b5.tif"
    local u_warped="${WORK_DIR}/dkss-u.warp.tif"
    local v_warped="${WORK_DIR}/dkss-v.warp.tif"
    local current_target="${CHART_DIR}/${WEATHER_PREFIX}current-arrows${WEATHER_SUFFIX}.mbtiles"

    if ! download_dmi_grib "${s3_url}" "${raw}"; then
        echo "DKSS download failed for +${FORECAST_HOUR}h, skipping current arrows." >&2
        return 1
    fi

    # Band 4 = UOGRD (u-component surface ocean current, m/s)
    # Band 5 = VOGRD (v-component surface ocean current, m/s)
    gdal_translate -q -of GTiff -b 4 "${raw}" "${u_band}" 2>/dev/null &
    local p_u=$!
    gdal_translate -q -of GTiff -b 5 "${raw}" "${v_band}" 2>/dev/null &
    local p_v=$!
    if ! wait_for_jobs_or_fail "${p_u}" "${p_v}"; then
        echo "Failed to extract UOGRD/VOGRD bands from DKSS GRIB." >&2
        rm -f "${raw}" "${u_band}" "${v_band}"
        return 1
    fi
    rm -f "${raw}"
    warp_grib "${u_band}" "${u_warped}" &
    local p_warp_u=$!
    warp_grib "${v_band}" "${v_warped}" &
    local p_warp_v=$!
    if ! wait_for_jobs_or_fail "${p_warp_u}" "${p_warp_v}"; then
        echo "Failed to warp DKSS current bands." >&2
        rm -f "${u_band}" "${v_band}" "${u_warped}" "${v_warped}"
        return 1
    fi
    rm -f "${u_band}" "${v_band}"

    local rc=0
    build_current_arrows "${u_warped}" "${v_warped}" "${current_target}" || rc=$?
    rm -f "${u_warped}" "${v_warped}"
    return ${rc}
}

download_bz2_grib() {
    local url="$1"
    local dest="$2"
    local archive="${dest}.bz2"

    echo "Downloading ${url}..."
    curl -fL --retry 5 --retry-delay 5 --retry-all-errors \
        --connect-timeout 15 --max-time 1800 \
        -o "${archive}" "${url}"

    local size_bytes
    size_bytes="$(stat -c%s "${archive}")"
    if [[ "${size_bytes}" -lt "${MIN_BYTES}" ]]; then
        echo "Downloaded archive is too small (${size_bytes} bytes), aborting" >&2
        rm -f "${archive}"
        exit 1
    fi

    bunzip2 -fc "${archive}" > "${dest}"

    if ! gdalinfo "${dest}" >/dev/null 2>&1; then
        echo "Downloaded file is not readable by GDAL as a GRIB dataset, aborting" >&2
        exit 1
    fi
}

warp_grib() {
    local src="$1"
    local dst="$2"
    gdalwarp -overwrite \
        -multi \
        -wo NUM_THREADS=ALL_CPUS \
        -of GTiff \
        -te "${LON_MIN}" "${LAT_MIN}" "${LON_MAX}" "${LAT_MAX}" \
        -te_srs EPSG:4326 \
        -t_srs EPSG:3857 \
        -r bilinear \
        -dstalpha \
        "${src}" "${dst}"
}

extract_primary_band() {
    local src="$1"
    local dst="$2"

    # Some ICON-D2 products (for example total precipitation) expose multiple
    # forecast slices as separate bands. Render the first band consistently.
    gdal_translate -q -of VRT -b 1 "${src}" "${dst}"
}

build_mbtiles() {
    local src="$1"
    local target="$2"
    local tmp="${target%.mbtiles}.tmp.mbtiles"
    local layer_name

    layer_name="$(basename "${target}" .mbtiles)"

    echo "Building MBTiles ${tmp}..."
    gdal_translate \
        -of MBTILES \
        -co TILE_FORMAT=PNG \
        -co MINZOOM="${MINZOOM}" \
        -co MAXZOOM="${MAXZOOM}" \
        "${src}" "${tmp}"

    # GDAL derives default MBTiles metadata from the temporary output filename,
    # so rewrite the metadata directly before comparing or moving the file.
    python3 - "${tmp}" "${layer_name}" "${MINZOOM}" "${MAXZOOM}" "${OVERZOOM_MAX_EXTRA_LEVELS}" <<'PY'
import io
import sqlite3
import sys

try:
    from PIL import Image
    RESAMPLE = Image.Resampling.BILINEAR
except Exception:
    Image = None
    RESAMPLE = None

path = sys.argv[1]
name = sys.argv[2]
requested_min_zoom = int(sys.argv[3])
requested_max_zoom = int(sys.argv[4])
max_extra_levels = int(sys.argv[5])

conn = sqlite3.connect(path)
try:
    native_max_zoom = conn.execute("SELECT MAX(zoom_level) FROM tiles").fetchone()[0]
    effective_max_zoom = requested_max_zoom

    if native_max_zoom is None:
        native_max_zoom = requested_max_zoom

    if requested_max_zoom > native_max_zoom:
        capped_max_zoom = min(requested_max_zoom, native_max_zoom + max_extra_levels)
        if capped_max_zoom > native_max_zoom and Image is not None:
            for z in range(native_max_zoom, capped_max_zoom):
                rows = conn.execute(
                    "SELECT tile_column, tile_row, tile_data FROM tiles WHERE zoom_level = ?",
                    (z,),
                ).fetchall()
                if not rows:
                    break

                xyz_max = (1 << z) - 1
                child_xyz_max = (1 << (z + 1)) - 1
                insert_rows = []

                for x, y_tms, blob in rows:
                    im = Image.open(io.BytesIO(blob)).convert("RGBA")
                    up = im.resize((512, 512), RESAMPLE)

                    parent_y_xyz = xyz_max - y_tms
                    children = [
                        (x * 2, parent_y_xyz * 2, up.crop((0, 0, 256, 256))),
                        (x * 2 + 1, parent_y_xyz * 2, up.crop((256, 0, 512, 256))),
                        (x * 2, parent_y_xyz * 2 + 1, up.crop((0, 256, 256, 512))),
                        (x * 2 + 1, parent_y_xyz * 2 + 1, up.crop((256, 256, 512, 512))),
                    ]

                    for cx, cy_xyz, cimg in children:
                        cy_tms = child_xyz_max - cy_xyz
                        out = io.BytesIO()
                        cimg.save(out, format="PNG", optimize=True)
                        insert_rows.append((z + 1, cx, cy_tms, sqlite3.Binary(out.getvalue())))

                conn.executemany(
                    "INSERT OR REPLACE INTO tiles(zoom_level, tile_column, tile_row, tile_data) VALUES (?, ?, ?, ?)",
                    insert_rows,
                )
                conn.commit()

            effective_max_zoom = capped_max_zoom
        else:
            # Cannot synthesize higher zoom tiles without Pillow support.
            effective_max_zoom = native_max_zoom
    else:
        effective_max_zoom = requested_max_zoom

    effective_min_zoom = min(requested_min_zoom, effective_max_zoom)

    conn.executemany(
        "DELETE FROM metadata WHERE name = ?",
        [("name",), ("description",), ("type",), ("minzoom",), ("maxzoom",)],
    )
    conn.executemany(
        "INSERT OR REPLACE INTO metadata(name, value) VALUES (?, ?)",
        [
            ("name", name),
            ("description", name),
            ("type", "overlay"),
            ("minzoom", str(effective_min_zoom)),
            ("maxzoom", str(effective_max_zoom)),
        ],
    )
    conn.commit()
finally:
    conn.close()
PY

    if [[ ! -s "${tmp}" ]]; then
        echo "Generated MBTiles is empty for ${target}, aborting" >&2
        exit 1
    fi

    if [[ -f "${target}" ]] && cmp -s "${target}" "${tmp}"; then
        echo "Overlay unchanged for ${target} — nothing to do."
        rm -f "${tmp}"
        return 1
    fi

    mv -f "${tmp}" "${target}"
    chmod 0644 "${target}"
    echo "Updated ${target}."
    return 0
}

render_icon_overlay() {
    local variable_dir="$1"
    local variable_suffix="$2"
    local output_name="$3"
    local icon_date="$4"
    local icon_cycle="$5"

    local url raw selected warped target rc
    url="https://opendata.dwd.de/weather/nwp/icon-d2/grib/${icon_cycle}/${variable_dir}/icon-d2_germany_regular-lat-lon_single-level_${icon_date}${icon_cycle}_${FORECAST_HOUR}_2d_${variable_suffix}.grib2.bz2"
    raw="${WORK_DIR}/${output_name}.grib2"
    selected="${WORK_DIR}/${output_name}.band1.vrt"
    warped="${WORK_DIR}/${output_name}.warp.tif"
    target="${CHART_DIR}/${WEATHER_PREFIX}${output_name}${WEATHER_SUFFIX}.mbtiles"

    download_bz2_grib "${url}" "${raw}" "${MIN_BYTES_ICON}"
    extract_primary_band "${raw}" "${selected}"
    warp_grib "${selected}" "${warped}"
    build_mbtiles "${warped}" "${target}"
    rc=$?
    rm -f "${raw}.bz2" "${raw}" "${selected}" "${warped}"
    return ${rc}
}

render_wave_overlay() {
    local wave_date="$1"
    local wave_cycle="$2"
    local url raw selected warped target rc
    url="https://opendata.dwd.de/weather/maritime/wave_models/ewam/grib/${wave_cycle}/swh/EWAM_SWH_${wave_date}${wave_cycle}_${WAVE_FORECAST_HOUR}.grib2.bz2"
    raw="${WORK_DIR}/ewam-wave-height.grib2"
    selected="${WORK_DIR}/ewam-wave-height.band1.vrt"
    warped="${WORK_DIR}/ewam-wave-height.warp.tif"
    target="${CHART_DIR}/${WEATHER_PREFIX}ewam-wave-height${WEATHER_SUFFIX}.mbtiles"

    download_bz2_grib "${url}" "${raw}" "${MIN_BYTES_WAVE}"
    extract_primary_band "${raw}" "${selected}"
    warp_grib "${selected}" "${warped}"
    build_mbtiles "${warped}" "${target}"
    rc=$?
    rm -f "${raw}.bz2" "${raw}" "${selected}" "${warped}"
    return ${rc}
}

build_wave_arrows() {
    # Renders wave direction arrows coloured by wave height into MBTiles.
    # Args: swh_tif  mwd_tif  target_mbtiles
    local swh_tif="$1"
    local mwd_tif="$2"
    local target="$3"
    local tmp="${target%.mbtiles}.tmp.mbtiles"
    local barb_zoom_max
    barb_zoom_max=$(( WIND_BARB_RENDER_ZOOM_MAX < max_zoom ? WIND_BARB_RENDER_ZOOM_MAX : max_zoom ))
    rm -f "${tmp}"

    python3 - "${swh_tif}" "${mwd_tif}" "${tmp}" \
        "${CURRENT_BARB_STEP}" "${CURRENT_ARROW_SCALE}" \
        "${min_zoom}" "${barb_zoom_max}" \
        "${WIND_BARB_STRIP_MB}" \
        "${WIND_BARB_WORKERS}" \
        "${BOAT_LAT:-0.0}" "${BOAT_LON:-0.0}" <<'PY'
import io, math, os, sqlite3, sys, multiprocessing
import numpy as np

try:
    import matplotlib
    matplotlib.use("Agg")
    from matplotlib.figure import Figure
    from matplotlib.backends.backend_agg import FigureCanvasAgg
    from matplotlib.colors import LinearSegmentedColormap
    from osgeo import gdal
    from PIL import Image
except Exception as exc:
    raise SystemExit(f"wave arrow rendering requires numpy, matplotlib, GDAL, Pillow: {exc}")

EARTH_CIRC = 40075016.686
TILE = 256

# Colour ramp: pale-cyan (calm) → teal → blue → deep-navy → crimson (rough)
# vmax_m = 4 m (Baltic/North Sea design range)
WAVE_CMAP = LinearSegmentedColormap.from_list("wave", [
    (0.00, (0.60, 0.92, 0.92)),
    (0.12, (0.00, 0.65, 0.70)),
    (0.30, (0.05, 0.25, 0.75)),
    (0.60, (0.02, 0.08, 0.45)),
    (1.00, (0.72, 0.05, 0.15)),
])
VMAX_M = 4.0

def _render_wave_zoom(z, swh_raw, mwd_raw, valid_raw, gt,
                     arrow_px_spacing, scale, max_strip_mb, temp_db_path,
                     x_min, x_max, y_min, y_max,
                     center_lat=0.0, center_lon=0.0):
    import io, math, sqlite3, sys
    import numpy as np
    import matplotlib
    matplotlib.use("Agg")
    from matplotlib.figure import Figure
    from matplotlib.backends.backend_agg import FigureCanvasAgg
    from matplotlib.colors import LinearSegmentedColormap, Normalize
    from PIL import Image
    EARTH_CIRC = 40075016.686
    TILE = 256
    WAVE_CMAP = LinearSegmentedColormap.from_list("wave", [
        (0.00, (0.60, 0.92, 0.92)),
        (0.12, (0.00, 0.65, 0.70)),
        (0.30, (0.05, 0.25, 0.75)),
        (0.60, (0.02, 0.08, 0.45)),
        (1.00, (0.72, 0.05, 0.15)),
    ])
    VMAX_M = 4.0

    def _tb(tx, ty_xyz, z):
        tw = EARTH_CIRC / (1 << z)
        xlo = -EARTH_CIRC / 2 + tx * tw
        yhi =  EARTH_CIRC / 2 - ty_xyz * tw
        return xlo, yhi - tw, xlo + tw, yhi

    def _btiles(xlo, ylo, xhi, yhi, z):
        tw = EARTH_CIRC / (1 << z)
        N = 1 << z
        tx0 = max(0, int(math.floor((xlo + EARTH_CIRC/2) / tw)))
        tx1 = min(N-1, int(math.ceil((xhi + EARTH_CIRC/2) / tw)) - 1)
        ty0 = max(0, int(math.floor((EARTH_CIRC/2 - yhi) / tw)))
        ty1 = min(N-1, int(math.ceil((EARTH_CIRC/2 - ylo) / tw)) - 1)
        return tx0, ty0, tx1, ty1

    grid_h, grid_w = swh_raw.shape
    gx0, gdx, _, gy0, _, gdy = gt
    conn = sqlite3.connect(temp_db_path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("CREATE TABLE IF NOT EXISTS tiles("
                 "zoom_level INT,tile_column INT,tile_row INT,tile_data BLOB,"
                 "PRIMARY KEY(zoom_level,tile_column,tile_row))")

    # Pre-compute direction unit vectors from mwd (degrees FROM, met convention).
    # Waves travel OPPOSITE to the FROM direction.
    mwd_rad = np.deg2rad(mwd_raw)
    u_dir = -np.sin(mwd_rad).astype("float32")  # eastward
    v_dir = -np.cos(mwd_rad).astype("float32")  # northward

    px_per_m = TILE * (1 << z) / EARTH_CIRC
    out_w = max(TILE, int(round((x_max - x_min) * px_per_m)))
    out_h = max(TILE, int(round((y_max - y_min) * px_per_m)))
    ppc = ((out_w / max(1, grid_w)) + (out_h / max(1, grid_h))) / 2.0
    step = max(1, int(round(arrow_px_spacing / ppc)))

    xs_g = gx0 + (np.arange(0, grid_w, step) + 0.5) * gdx
    ys_g = gy0 + (np.arange(0, grid_h, step) + 0.5) * gdy
    # Stagger wave arrows 10px east so they don't overlap wind barbs or current arrows
    _pm = EARTH_CIRC / ((1 << z) * TILE)   # metres per screen pixel at this zoom
    xs_g = xs_g + 10.0 * _pm
    SWH = swh_raw[::step, ::step]
    UD  = u_dir[::step, ::step]
    VD  = v_dir[::step, ::step]
    VM  = valid_raw[::step, ::step]
    Xg, Yg = np.meshgrid(xs_g, ys_g)
    Ka = VM & np.isfinite(SWH) & np.isfinite(UD)
    # Arrow length = sqrt(swh) for visual scaling; calm (<0.1 m) gets tiny stub
    mag = np.sqrt(np.maximum(SWH, 0.1))
    Un = UD * mag
    Vn = VD * mag

    tx0, ty0, tx1, ty1 = _btiles(x_min, y_min, x_max, y_max, z)
    n_tx = tx1 - tx0 + 1
    overhead = 3
    max_strip_tiles_h = max(1, (max_strip_mb * 1024 * 1024) //
                            ((n_tx + 4) * TILE * TILE * 4 * overhead) - 2)
    sh = min(max_strip_tiles_h, max(1, ty1 - ty0 + 1))
    print(f"z{z}: {n_tx}x{ty1-ty0+1} tiles, step={step}, strips of {sh} rows (waves)",
          file=sys.stderr, flush=True)
    n_tiles = 0
    q_scale = 1.0 / (scale * 20.0)
    def _lat_to_tile_y(lat, zoom):
        lat = max(min(lat, 85.0511), -85.0511)
        rlat = math.radians(lat)
        n = 1 << zoom
        y = (1.0 - math.log(math.tan(rlat) + 1.0 / math.cos(rlat)) / math.pi) / 2.0
        return int(max(0, min(n - 1, math.floor(y * n))))

    strip_starts = list(range(ty0, ty1 + 1, sh))
    if abs(center_lat) > 0.0001:
        center_ty = _lat_to_tile_y(center_lat, z)

        def _strip_dist(s0):
            s1 = min(s0 + sh - 1, ty1)
            smid = (s0 + s1) // 2
            return abs(smid - center_ty)

        strip_starts.sort(key=_strip_dist)

    for s_ty0 in strip_starts:
        s_ty1 = min(s_ty0 + sh - 1, ty1)
        p_tx0 = max(0, tx0-1);  p_tx1 = min((1<<z)-1, tx1+1)
        p_ty0 = max(0, s_ty0-1); p_ty1 = min((1<<z)-1, s_ty1+1)
        bxlo, _, _, byhi = _tb(p_tx0, p_ty0, z)
        _, _, bxhi, _    = _tb(p_tx1, p_ty0, z)
        _, bylo, _, _    = _tb(p_tx0, p_ty1, z)
        fw = (p_tx1 - p_tx0 + 1) * TILE
        fh = (p_ty1 - p_ty0 + 1) * TILE
        K = Ka & (Xg >= bxlo) & (Xg <= bxhi) & (Yg >= bylo) & (Yg <= byhi)
        fig = Figure(figsize=(fw/100., fh/100.), dpi=100)
        canvas = FigureCanvasAgg(fig)
        ax = fig.add_axes([0,0,1,1])
        ax.set_facecolor((0,0,0,0)); fig.patch.set_alpha(0)
        ax.set_xlim(bxlo, bxhi); ax.set_ylim(bylo, byhi)
        ax.axis("off")
        if np.any(K):
            ax.quiver(Xg[K], Yg[K], Un[K], Vn[K],   # white halo
                      color=(1, 1, 1, 0.65),
                      units='dots', scale=q_scale,
                      width=3.5, headwidth=4.5, headlength=5.5,
                      pivot='mid')
            ax.quiver(Xg[K], Yg[K], Un[K], Vn[K], SWH[K],  # colour fill
                      cmap=WAVE_CMAP, norm=Normalize(vmin=0.0, vmax=VMAX_M),
                      alpha=0.88,
                      units='dots', scale=q_scale,
                      width=2.0, headwidth=3.2, headlength=4.2,
                      pivot='mid')
        canvas.draw()
        buf = np.asarray(canvas.buffer_rgba()).copy()
        del fig, canvas
        for ty in range(s_ty0, s_ty1 + 1):
            row = (ty - p_ty0) * TILE
            for tx in range(tx0, tx1 + 1):
                col = (tx - p_tx0) * TILE
                pix = buf[row:row+TILE, col:col+TILE]
                if pix.shape[0] < TILE or pix.shape[1] < TILE: continue
                if pix[:,:,3].max() == 0: continue
                b = io.BytesIO()
                Image.fromarray(pix,"RGBA").save(b,"PNG",optimize=True)
                tms_y = ((1<<z)-1) - ty
                conn.execute("INSERT OR REPLACE INTO tiles VALUES(?,?,?,?)",
                             (z, tx, tms_y, sqlite3.Binary(b.getvalue())))
                n_tiles += 1
        conn.commit()
        del buf
    import gc; gc.collect()
    conn.close()
    return z, n_tiles, temp_db_path


swh_path, mwd_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
arrow_px_spacing = max(4, int(sys.argv[4]))
scale = max(0.1, float(sys.argv[5]))
zoom_min = int(sys.argv[6])
zoom_max = int(sys.argv[7])
max_strip_mb = int(sys.argv[8])
n_workers = max(1, int(sys.argv[9]))
center_lat = float(sys.argv[10]) if len(sys.argv) > 10 and sys.argv[10] else 0.0
center_lon = float(sys.argv[11]) if len(sys.argv) > 11 and sys.argv[11] else 0.0

swh_ds = gdal.Open(swh_path)
mwd_ds = gdal.Open(mwd_path)
if swh_ds is None or mwd_ds is None:
    raise SystemExit("unable to open wave swh/mwd rasters")
swh_raw = swh_ds.GetRasterBand(1).ReadAsArray().astype("float32")
mwd_raw = mwd_ds.GetRasterBand(1).ReadAsArray().astype("float32")
if swh_raw.shape != mwd_raw.shape:
    # Resample mwd to swh resolution if they differ (EWAM grids may differ)
    from osgeo import gdalconst
    mem_drv = gdal.GetDriverByName("MEM")
    dst = mem_drv.Create("", swh_ds.RasterXSize, swh_ds.RasterYSize, 1, gdalconst.GDT_Float32)
    dst.SetGeoTransform(swh_ds.GetGeoTransform())
    dst.SetProjection(swh_ds.GetProjection())
    gdal.ReprojectImage(mwd_ds, dst, None, None, gdalconst.GRA_Bilinear)
    mwd_raw = dst.GetRasterBand(1).ReadAsArray().astype("float32")
valid_raw = (swh_ds.GetRasterBand(2).ReadAsArray() > 0) if swh_ds.RasterCount >= 2 \
            else np.ones(swh_raw.shape, bool)
valid_raw &= np.isfinite(swh_raw) & np.isfinite(mwd_raw) & (swh_raw > 0.05)
gt = list(swh_ds.GetGeoTransform())
swh_ds = mwd_ds = None

grid_h, grid_w = swh_raw.shape
gx0, gdx, _, gy0, _, gdy = gt
x_min = min(gx0, gx0 + grid_w * gdx)
x_max = max(gx0, gx0 + grid_w * gdx)
y_min = min(gy0, gy0 + grid_h * gdy)
y_max = max(gy0, gy0 + grid_h * gdy)

conn = sqlite3.connect(out_path)
conn.execute("PRAGMA journal_mode=WAL")
conn.execute("CREATE TABLE IF NOT EXISTS metadata(name TEXT PRIMARY KEY,value TEXT)")
conn.execute("CREATE TABLE IF NOT EXISTS tiles("
             "zoom_level INT,tile_column INT,tile_row INT,tile_data BLOB,"
             "PRIMARY KEY(zoom_level,tile_column,tile_row))")
conn.execute("DELETE FROM metadata")
conn.execute("DELETE FROM tiles")
conn.commit()

zoom_levels = list(range(zoom_min, zoom_max + 1))
actual_workers = min(n_workers, len(zoom_levels))
print(f"Rendering wave arrows z{zoom_min}-{zoom_max} with {actual_workers} worker(s)",
      file=sys.stderr)

ctx = multiprocessing.get_context("fork")
with ctx.Pool(processes=actual_workers) as pool:
    results = pool.starmap(_render_wave_zoom, [
        (z, swh_raw, mwd_raw, valid_raw, gt,
         arrow_px_spacing, scale, max_strip_mb,
         out_path + f".z{z}.tmp",
         x_min, x_max, y_min, y_max, center_lat, center_lon)
        for z in zoom_levels
    ])

n_tiles_total = 0
for z_done, n_z, temp_db in results:
    src = sqlite3.connect(temp_db)
    rows = src.execute(
        "SELECT zoom_level,tile_column,tile_row,tile_data FROM tiles"
    ).fetchall()
    conn.executemany("INSERT OR REPLACE INTO tiles VALUES(?,?,?,?)", rows)
    conn.commit()
    src.close()
    os.unlink(temp_db)
    n_tiles_total += n_z
    print(f"z{z_done}: merged {n_z} tiles", file=sys.stderr)

def m2ll(x, y):
    return (math.degrees(x/6378137),
            math.degrees(2*math.atan(math.exp(y/6378137))-math.pi/2))
lon0,lat0 = m2ll(x_min,y_min); lon1,lat1 = m2ll(x_max,y_max)
conn.executemany("INSERT OR REPLACE INTO metadata VALUES(?,?)",[
    ("name","weather-wave-direction"),("description","weather-wave-direction"),
    ("type","overlay"),("format","png"),
    ("minzoom",str(zoom_min)),("maxzoom",str(zoom_max)),
    ("bounds",f"{lon0:.6f},{lat0:.6f},{lon1:.6f},{lat1:.6f}"),
    ("version","1.1"),])
conn.commit(); conn.close()
print(f"wave arrows: {n_tiles_total} tiles z{zoom_min}-{zoom_max}", file=sys.stderr)
PY

    if [[ ! -s "${tmp}" ]]; then
        echo "Generated MBTiles is empty for ${target}, aborting" >&2
        exit 1
    fi
    if [[ -f "${target}" ]] && cmp -s "${target}" "${tmp}"; then
        echo "Overlay unchanged for ${target} — nothing to do."
        rm -f "${tmp}"
        return 1
    fi
    mv -f "${tmp}" "${target}"
    chmod 0644 "${target}"
    echo "Updated ${target}."
    return 0
}

render_wave_style() {
    # Downloads EWAM SWH + MWD, renders height (GDAL colour-relief) and
    # direction (arrow overlay) tiles into separate MBTiles.
    local wave_date="$1"
    local wave_cycle="$2"
    local swh_url mwd_url
    local swh_raw mwd_raw swh_selected mwd_selected swh_warped mwd_warped
    local height_target dir_target ewam_fh ewam_fh_str
    local updated=0

    # EWAM provides 3-hourly output only; round FORECAST_HOUR down to nearest 3h.
    ewam_fh=$(( (10#${FORECAST_HOUR} / 3) * 3 ))
    (( ewam_fh < 3 )) && ewam_fh=3
    printf -v ewam_fh_str '%03d' "${ewam_fh}"

    swh_url="https://opendata.dwd.de/weather/maritime/wave_models/ewam/grib/${wave_cycle}/swh/EWAM_SWH_${wave_date}${wave_cycle}_${ewam_fh_str}.grib2.bz2"
    mwd_url="https://opendata.dwd.de/weather/maritime/wave_models/ewam/grib/${wave_cycle}/mwd/EWAM_MWD_${wave_date}${wave_cycle}_${ewam_fh_str}.grib2.bz2"

    swh_raw="${WORK_DIR}/wave-swh.grib2"
    mwd_raw="${WORK_DIR}/wave-mwd.grib2"
    swh_selected="${WORK_DIR}/wave-swh.band1.vrt"
    mwd_selected="${WORK_DIR}/wave-mwd.band1.vrt"
    swh_warped="${WORK_DIR}/wave-swh.warp.tif"
    mwd_warped="${WORK_DIR}/wave-mwd.warp.tif"

    height_target="${CHART_DIR}/${WEATHER_PREFIX}wave-height${WEATHER_SUFFIX}.mbtiles"
    dir_target="${CHART_DIR}/${WEATHER_PREFIX}wave-direction${WEATHER_SUFFIX}.mbtiles"

    download_bz2_grib "${swh_url}" "${swh_raw}" "${MIN_BYTES_WAVE}"
    download_bz2_grib "${mwd_url}" "${mwd_raw}" "${MIN_BYTES_WAVE}"
    extract_primary_band "${swh_raw}" "${swh_selected}"
    extract_primary_band "${mwd_raw}" "${mwd_selected}"
    warp_grib "${swh_selected}" "${swh_warped}"
    warp_grib "${mwd_selected}" "${mwd_warped}"

    if build_mbtiles "${swh_warped}" "${height_target}"; then
        updated=1
    fi
    if build_wave_arrows "${swh_warped}" "${mwd_warped}" "${dir_target}"; then
        updated=1
    fi

    rm -f "${swh_raw}.bz2" "${swh_raw}" "${swh_selected}" "${swh_warped}" \
          "${mwd_raw}.bz2" "${mwd_raw}" "${mwd_selected}" "${mwd_warped}"

    [[ "${updated}" -eq 1 ]] && return 0 || return 1
}

build_wind_speed_colored() {
    local u_tif="$1"
    local v_tif="$2"
    local out_tif="$3"
    local speed_tif color_file calc_cmd

    if command -v gdal_calc.py >/dev/null 2>&1; then
        calc_cmd="gdal_calc.py"
    elif command -v gdal_calc >/dev/null 2>&1; then
        calc_cmd="gdal_calc"
    else
        echo "Skipping wind speed colors: missing gdal_calc(.py)." >&2
        return 1
    fi
    if ! command -v gdaldem >/dev/null 2>&1; then
        echo "Skipping wind speed colors: missing gdaldem." >&2
        return 1
    fi

    speed_tif="${WORK_DIR}/wind-speed-kts.float.tif"
    color_file="${WORK_DIR}/wind-speed-kts.clr"

    "${calc_cmd}" \
        --quiet --overwrite \
        -A "${u_tif}" --A_band=1 \
        -B "${v_tif}" --B_band=1 \
        -C "${u_tif}" --C_band=2 \
        --outfile "${speed_tif}" \
        --type Float32 \
        --NoDataValue=-9999 \
        --calc "numpy.where(C>0,numpy.sqrt(A*A+B*B)*1.94384449,-9999)"

    cat > "${color_file}" <<'EOF'
nv 0 0 0 0
0 0 0 0 0
3 0 0 0 0
6 0 0 160 60
8 0 96 0 100
10 0 140 0 130
12 0 180 0 150
14 64 210 64 160
16 100 230 80 170
20 200 200 0 180
25 255 140 0 190
30 255 60 0 210
60 255 0 0 220
EOF

    gdaldem color-relief \
        -alpha \
        "${speed_tif}" "${color_file}" "${out_tif}"

    rm -f "${speed_tif}" "${color_file}"
}

build_wind_barbs() {
    local u_tif="$1"
    local v_tif="$2"
    local target="$3"
    local tmp="${target%.mbtiles}.tmp.mbtiles"

    # Render natively for zoom levels min_zoom..barb_zoom_max using strip rendering
    # so that peak RSS stays within WIND_BARB_STRIP_MB on memory-limited hosts.
    local barb_zoom_max
    barb_zoom_max=$(( WIND_BARB_RENDER_ZOOM_MAX < max_zoom ? WIND_BARB_RENDER_ZOOM_MAX : max_zoom ))

    rm -f "${tmp}"

    python3 - "${u_tif}" "${v_tif}" "${tmp}" \
        "${WIND_BARB_STEP}" "${WIND_BARB_RENDER_SCALE}" \
        "${min_zoom}" "${barb_zoom_max}" \
        "${WIND_BARB_WHITE_INFILL_MIN_ZOOM}" \
        "${WIND_BARB_STRIP_MB}" \
        "${WIND_BARB_WORKERS}" \
        "${BOAT_LAT:-0.0}" "${BOAT_LON:-0.0}" <<'PY'
import io, math, os, sqlite3, sys, multiprocessing
import numpy as np

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from osgeo import gdal
    from PIL import Image
except Exception as exc:
    raise SystemExit(f"wind barb rendering requires numpy, matplotlib, GDAL, Pillow: {exc}")

EARTH_CIRC = 40075016.686
TILE = 256

# ---------------------------------------------------------------------------
# Worker — defined at module level so multiprocessing fork can find it.
# ---------------------------------------------------------------------------
def _render_barb_zoom(z, u_raw, v_raw, valid_raw, gt,
                      barb_px_spacing, scale, white_infill_min_zoom,
                      max_strip_mb, temp_db_path, x_min, x_max, y_min, y_max,
                      center_lat=0.0, center_lon=0.0):
    """Render wind barb strips for one zoom level into a private temp SQLite file."""
    import io, math, sqlite3, sys
    import numpy as np
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from PIL import Image
    EARTH_CIRC = 40075016.686
    TILE = 256

    def _tb(tx, ty_xyz, z):
        tw = EARTH_CIRC / (1 << z)
        xlo = -EARTH_CIRC / 2 + tx * tw
        yhi =  EARTH_CIRC / 2 - ty_xyz * tw
        return xlo, yhi - tw, xlo + tw, yhi

    def _btiles(xlo, ylo, xhi, yhi, z):
        tw = EARTH_CIRC / (1 << z)
        N = 1 << z
        tx0 = max(0, int(math.floor((xlo + EARTH_CIRC/2) / tw)))
        tx1 = min(N-1, int(math.ceil((xhi + EARTH_CIRC/2) / tw)) - 1)
        ty0 = max(0, int(math.floor((EARTH_CIRC/2 - yhi) / tw)))
        ty1 = min(N-1, int(math.ceil((EARTH_CIRC/2 - ylo) / tw)) - 1)
        return tx0, ty0, tx1, ty1

    grid_h, grid_w = u_raw.shape
    gx0, gdx, _, gy0, _, gdy = gt
    conn = sqlite3.connect(temp_db_path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("CREATE TABLE IF NOT EXISTS tiles("
                 "zoom_level INT,tile_column INT,tile_row INT,tile_data BLOB,"
                 "PRIMARY KEY(zoom_level,tile_column,tile_row))")
    px_per_m = TILE * (1 << z) / EARTH_CIRC
    out_w = max(TILE, int(round((x_max - x_min) * px_per_m)))
    out_h = max(TILE, int(round((y_max - y_min) * px_per_m)))
    ppc = ((out_w / max(1, grid_w)) + (out_h / max(1, grid_h))) / 2.0
    step = max(1, int(round(barb_px_spacing / ppc)))
    xs_g = gx0 + (np.arange(0, grid_w, step) + 0.5) * gdx
    ys_g = gy0 + (np.arange(0, grid_h, step) + 0.5) * gdy
    UU = u_raw[::step, ::step] * 1.94384449
    VV = v_raw[::step, ::step] * 1.94384449
    VM = valid_raw[::step, ::step]
    Xg, Yg = np.meshgrid(xs_g, ys_g)
    Ka = VM & np.isfinite(UU) & np.isfinite(VV)
    white = (z >= white_infill_min_zoom)
    tx0, ty0, tx1, ty1 = _btiles(x_min, y_min, x_max, y_max, z)
    n_tx = tx1 - tx0 + 1
    overhead = 3
    max_strip_tiles_h = max(1, (max_strip_mb * 1024 * 1024) //
                            ((n_tx + 4) * TILE * TILE * 4 * overhead) - 2)
    sh = min(max_strip_tiles_h, max(1, ty1 - ty0 + 1))
    print(f"z{z}: {n_tx}x{ty1-ty0+1} tiles, step={step}, strips of {sh} tile rows",
          file=sys.stderr, flush=True)
    n_tiles = 0
    def _lat_to_tile_y(lat, zoom):
        lat = max(min(lat, 85.0511), -85.0511)
        rlat = math.radians(lat)
        n = 1 << zoom
        y = (1.0 - math.log(math.tan(rlat) + 1.0 / math.cos(rlat)) / math.pi) / 2.0
        return int(max(0, min(n - 1, math.floor(y * n))))

    strip_starts = list(range(ty0, ty1 + 1, sh))
    if abs(center_lat) > 0.0001:
        center_ty = _lat_to_tile_y(center_lat, z)

        def _strip_dist(s0):
            s1 = min(s0 + sh - 1, ty1)
            smid = (s0 + s1) // 2
            return abs(smid - center_ty)

        strip_starts.sort(key=_strip_dist)

    for s_ty0 in strip_starts:
        s_ty1 = min(s_ty0 + sh - 1, ty1)
        p_tx0 = max(0, tx0-1);  p_tx1 = min((1<<z)-1, tx1+1)
        p_ty0 = max(0, s_ty0-1); p_ty1 = min((1<<z)-1, s_ty1+1)
        bxlo, _, _, byhi = _tb(p_tx0, p_ty0, z)
        _, _, bxhi, _    = _tb(p_tx1, p_ty0, z)
        _, bylo, _, _    = _tb(p_tx0, p_ty1, z)
        fw = (p_tx1 - p_tx0 + 1) * TILE
        fh = (p_ty1 - p_ty0 + 1) * TILE
        K = Ka & (Xg >= bxlo) & (Xg <= bxhi) & (Yg >= bylo) & (Yg <= byhi)
        fig = plt.figure(figsize=(fw/100., fh/100.), dpi=100)
        ax  = fig.add_axes([0,0,1,1])
        ax.set_facecolor((0,0,0,0)); fig.patch.set_alpha(0)
        ax.set_xlim(bxlo, bxhi); ax.set_ylim(bylo, byhi)
        ax.axis("off")
        if np.any(K):
            kw = dict(length=4.8, sizes={"emptybarb":.1,"spacing":.2,"height":.45})
            ax.barbs(Xg[K],Yg[K],UU[K],VV[K], linewidth=scale,
                     barbcolor=(0,0,0,.85), flagcolor=(0,0,0,.85), **kw)
            if white:
                ax.barbs(Xg[K],Yg[K],UU[K],VV[K], linewidth=.55*scale,
                         barbcolor=(1,1,1,.92), flagcolor=(1,1,1,.92), **kw)
        fig.canvas.draw()
        buf = np.asarray(fig.canvas.buffer_rgba()).copy()
        plt.close(fig)
        for ty in range(s_ty0, s_ty1 + 1):
            row = (ty - p_ty0) * TILE
            for tx in range(tx0, tx1 + 1):
                col = (tx - p_tx0) * TILE
                pix = buf[row:row+TILE, col:col+TILE]
                if pix.shape[0] < TILE or pix.shape[1] < TILE: continue
                if pix[:,:,3].max() == 0: continue
                b = io.BytesIO()
                Image.fromarray(pix,"RGBA").save(b,"PNG",optimize=True)
                tms_y = ((1<<z)-1) - ty
                conn.execute("INSERT OR REPLACE INTO tiles VALUES(?,?,?,?)",
                             (z, tx, tms_y, sqlite3.Binary(b.getvalue())))
                n_tiles += 1
        conn.commit()
        del buf
    import gc; gc.collect()
    conn.close()
    return z, n_tiles, temp_db_path


# ---------------------------------------------------------------------------
# Main script
# ---------------------------------------------------------------------------
u_path, v_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
barb_px_spacing = max(4, int(sys.argv[4]))
scale = max(0.1, float(sys.argv[5]))
zoom_min = int(sys.argv[6])
zoom_max = int(sys.argv[7])
white_infill_min_zoom = int(sys.argv[8])
max_strip_mb = int(sys.argv[9])
n_workers = max(1, int(sys.argv[10]))
center_lat = float(sys.argv[11]) if len(sys.argv) > 11 and sys.argv[11] else 0.0
center_lon = float(sys.argv[12]) if len(sys.argv) > 12 and sys.argv[12] else 0.0

u_ds = gdal.Open(u_path)
v_ds = gdal.Open(v_path)
if u_ds is None or v_ds is None:
    raise SystemExit("unable to open wind u/v rasters")
u_raw = u_ds.GetRasterBand(1).ReadAsArray().astype("float32")
v_raw = v_ds.GetRasterBand(1).ReadAsArray().astype("float32")
if u_raw.shape != v_raw.shape:
    raise SystemExit("u/v raster dimensions do not match")
valid_raw = (u_ds.GetRasterBand(2).ReadAsArray() > 0) if u_ds.RasterCount >= 2 \
            else np.ones(u_raw.shape, bool)
valid_raw &= np.isfinite(u_raw) & np.isfinite(v_raw)
gt = list(u_ds.GetGeoTransform())  # plain list — serialisable by pickle
u_ds = v_ds = None  # close GDAL handles before fork

grid_h, grid_w = u_raw.shape
gx0, gdx, _, gy0, _, gdy = gt
x_min = min(gx0, gx0 + grid_w * gdx)
x_max = max(gx0, gx0 + grid_w * gdx)
y_min = min(gy0, gy0 + grid_h * gdy)
y_max = max(gy0, gy0 + grid_h * gdy)

conn = sqlite3.connect(out_path)
conn.execute("PRAGMA journal_mode=WAL")
conn.execute("CREATE TABLE IF NOT EXISTS metadata(name TEXT PRIMARY KEY,value TEXT)")
conn.execute("CREATE TABLE IF NOT EXISTS tiles("
             "zoom_level INT,tile_column INT,tile_row INT,tile_data BLOB,"
             "PRIMARY KEY(zoom_level,tile_column,tile_row))")
conn.execute("DELETE FROM metadata")
conn.execute("DELETE FROM tiles")
conn.commit()

zoom_levels = list(range(zoom_min, zoom_max + 1))
actual_workers = min(n_workers, len(zoom_levels))
print(f"Rendering barbs z{zoom_min}-{zoom_max} with {actual_workers} worker(s)",
      file=sys.stderr)

ctx = multiprocessing.get_context("fork")
with ctx.Pool(processes=actual_workers) as pool:
    results = pool.starmap(_render_barb_zoom, [
        (z, u_raw, v_raw, valid_raw, gt,
         barb_px_spacing, scale, white_infill_min_zoom,
         max_strip_mb, out_path + f".z{z}.tmp",
         x_min, x_max, y_min, y_max, center_lat, center_lon)
        for z in zoom_levels
    ])

n_tiles_total = 0
for z_done, n_z, temp_db in results:
    src = sqlite3.connect(temp_db)
    rows = src.execute(
        "SELECT zoom_level,tile_column,tile_row,tile_data FROM tiles"
    ).fetchall()
    conn.executemany("INSERT OR REPLACE INTO tiles VALUES(?,?,?,?)", rows)
    conn.commit()
    src.close()
    os.unlink(temp_db)
    n_tiles_total += n_z
    print(f"z{z_done}: merged {n_z} tiles", file=sys.stderr)

def m2ll(x, y):
    return (math.degrees(x/6378137),
            math.degrees(2*math.atan(math.exp(y/6378137))-math.pi/2))
lon0,lat0 = m2ll(x_min,y_min); lon1,lat1 = m2ll(x_max,y_max)
conn.executemany("INSERT OR REPLACE INTO metadata VALUES(?,?)",[
    ("name","weather-wind-barbs"),("description","weather-wind-barbs"),
    ("type","overlay"),("format","png"),
    ("minzoom",str(zoom_min)),("maxzoom",str(zoom_max)),
    ("bounds",f"{lon0:.6f},{lat0:.6f},{lon1:.6f},{lat1:.6f}"),
    ("version","1.1"),])
conn.commit(); conn.close()
print(f"wind barbs: {n_tiles_total} tiles z{zoom_min}-{zoom_max}", file=sys.stderr)
PY

    if [[ ! -s "${tmp}" ]]; then
        echo "Generated MBTiles is empty for ${target}, aborting" >&2
        exit 1
    fi

    if [[ -f "${target}" ]] && cmp -s "${target}" "${tmp}"; then
        echo "Overlay unchanged for ${target} — nothing to do."
        rm -f "${tmp}"
        return 1
    fi

    mv -f "${tmp}" "${target}"
    chmod 0644 "${target}"
    echo "Updated ${target}."
    return 0
}

render_wind_style() {
    local icon_date="$1"
    local icon_cycle="$2"
    local u_url v_url
    local u_raw v_raw u_selected v_selected u_warp v_warp
    local speed_rgba
    local speed_target barbs_target
    local updated=0

    u_url="https://opendata.dwd.de/weather/nwp/icon-d2/grib/${icon_cycle}/u_10m/icon-d2_germany_regular-lat-lon_single-level_${icon_date}${icon_cycle}_${FORECAST_HOUR}_2d_u_10m.grib2.bz2"
    v_url="https://opendata.dwd.de/weather/nwp/icon-d2/grib/${icon_cycle}/v_10m/icon-d2_germany_regular-lat-lon_single-level_${icon_date}${icon_cycle}_${FORECAST_HOUR}_2d_v_10m.grib2.bz2"

    u_raw="${WORK_DIR}/wind-style-u_10m.grib2"
    v_raw="${WORK_DIR}/wind-style-v_10m.grib2"
    u_selected="${WORK_DIR}/wind-style-u_10m.band1.vrt"
    v_selected="${WORK_DIR}/wind-style-v_10m.band1.vrt"
    u_warp="${WORK_DIR}/wind-style-u_10m.warp.tif"
    v_warp="${WORK_DIR}/wind-style-v_10m.warp.tif"
    speed_rgba="${WORK_DIR}/wind-speed-colored.rgba.tif"

    speed_target="${CHART_DIR}/${WEATHER_PREFIX}wind-speed-kts${WEATHER_SUFFIX}.mbtiles"
    barbs_target="${CHART_DIR}/${WEATHER_PREFIX}wind-barbs${WEATHER_SUFFIX}.mbtiles"

    download_bz2_grib "${u_url}" "${u_raw}" "${MIN_BYTES_ICON}" &
    local p_dl_u=$!
    download_bz2_grib "${v_url}" "${v_raw}" "${MIN_BYTES_ICON}" &
    local p_dl_v=$!
    if ! wait_for_jobs_or_fail "${p_dl_u}" "${p_dl_v}"; then
        echo "Failed to download ICON-D2 u/v wind GRIBs." >&2
        rm -f "${u_raw}.bz2" "${v_raw}.bz2" "${u_raw}" "${v_raw}"
        return 1
    fi

    extract_primary_band "${u_raw}" "${u_selected}" &
    local p_ext_u=$!
    extract_primary_band "${v_raw}" "${v_selected}" &
    local p_ext_v=$!
    if ! wait_for_jobs_or_fail "${p_ext_u}" "${p_ext_v}"; then
        echo "Failed to extract ICON-D2 u/v wind bands." >&2
        rm -f "${u_raw}.bz2" "${v_raw}.bz2" "${u_raw}" "${v_raw}" "${u_selected}" "${v_selected}"
        return 1
    fi

    warp_grib "${u_selected}" "${u_warp}" &
    local p_warp_u=$!
    warp_grib "${v_selected}" "${v_warp}" &
    local p_warp_v=$!
    if ! wait_for_jobs_or_fail "${p_warp_u}" "${p_warp_v}"; then
        echo "Failed to warp ICON-D2 u/v wind rasters." >&2
        rm -f "${u_raw}.bz2" "${v_raw}.bz2" "${u_raw}" "${v_raw}" \
            "${u_selected}" "${v_selected}" "${u_warp}" "${v_warp}"
        return 1
    fi

    if build_wind_speed_colored "${u_warp}" "${v_warp}" "${speed_rgba}"; then
        if build_mbtiles "${speed_rgba}" "${speed_target}"; then
            updated=1
        fi
    else
        echo "Skipping wind speed colors: required tooling is unavailable." >&2
    fi

    if build_wind_barbs "${u_warp}" "${v_warp}" "${barbs_target}"; then
        updated=1
    else
        echo "Skipping wind barbs: matplotlib/numpy support is unavailable in the runtime." >&2
    fi

    rm -f "${u_raw}.bz2" "${v_raw}.bz2" "${u_raw}" "${v_raw}" \
        "${u_selected}" "${v_selected}" "${u_warp}" "${v_warp}" \
        "${speed_rgba}"

    if [[ "${updated}" -eq 1 ]]; then
        return 0
    fi
    return 1
}

build_current_arrows() {
    local u_tif="$1"
    local v_tif="$2"
    local target="$3"
    local tmp="${target%.mbtiles}.tmp.mbtiles"
    local barb_zoom_max
    barb_zoom_max=$(( WIND_BARB_RENDER_ZOOM_MAX < max_zoom ? WIND_BARB_RENDER_ZOOM_MAX : max_zoom ))

    rm -f "${tmp}"

    python3 - "${u_tif}" "${v_tif}" "${tmp}" \
        "${CURRENT_BARB_STEP}" "${CURRENT_ARROW_SCALE}" \
        "${min_zoom}" "${barb_zoom_max}" \
        "${WIND_BARB_STRIP_MB}" \
        "${WIND_BARB_WORKERS}" \
        "${BOAT_LAT:-0.0}" "${BOAT_LON:-0.0}" <<'PY'
import io, math, os, sqlite3, sys, multiprocessing
import numpy as np

try:
    import matplotlib
    matplotlib.use("Agg")
    from matplotlib.figure import Figure
    from matplotlib.backends.backend_agg import FigureCanvasAgg
    from osgeo import gdal
    from PIL import Image
except Exception as exc:
    raise SystemExit(f"current arrow rendering requires numpy, matplotlib, GDAL, Pillow: {exc}")

EARTH_CIRC = 40075016.686
TILE = 256

def _render_arrow_zoom(z, u_raw, v_raw, valid_raw, gt,
                       arrow_px_spacing, scale, max_strip_mb, temp_db_path,
                       x_min, x_max, y_min, y_max,
                       center_lat=0.0, center_lon=0.0):
    """Render ocean current arrows for one zoom level into a private temp SQLite file."""
    import io, math, sqlite3, sys
    import numpy as np
    import matplotlib
    matplotlib.use("Agg")
    from matplotlib.figure import Figure
    from matplotlib.backends.backend_agg import FigureCanvasAgg
    from PIL import Image
    EARTH_CIRC = 40075016.686
    TILE = 256

    def _tb(tx, ty_xyz, z):
        tw = EARTH_CIRC / (1 << z)
        xlo = -EARTH_CIRC / 2 + tx * tw
        yhi =  EARTH_CIRC / 2 - ty_xyz * tw
        return xlo, yhi - tw, xlo + tw, yhi

    def _btiles(xlo, ylo, xhi, yhi, z):
        tw = EARTH_CIRC / (1 << z)
        N = 1 << z
        tx0 = max(0, int(math.floor((xlo + EARTH_CIRC/2) / tw)))
        tx1 = min(N-1, int(math.ceil((xhi + EARTH_CIRC/2) / tw)) - 1)
        ty0 = max(0, int(math.floor((EARTH_CIRC/2 - yhi) / tw)))
        ty1 = min(N-1, int(math.ceil((EARTH_CIRC/2 - ylo) / tw)) - 1)
        return tx0, ty0, tx1, ty1

    grid_h, grid_w = u_raw.shape
    gx0, gdx, _, gy0, _, gdy = gt
    conn = sqlite3.connect(temp_db_path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("CREATE TABLE IF NOT EXISTS tiles("
                 "zoom_level INT,tile_column INT,tile_row INT,tile_data BLOB,"
                 "PRIMARY KEY(zoom_level,tile_column,tile_row))")
    px_per_m = TILE * (1 << z) / EARTH_CIRC
    out_w = max(TILE, int(round((x_max - x_min) * px_per_m)))
    out_h = max(TILE, int(round((y_max - y_min) * px_per_m)))
    ppc = ((out_w / max(1, grid_w)) + (out_h / max(1, grid_h))) / 2.0
    step = max(1, int(round(arrow_px_spacing / ppc)))
    xs_g = gx0 + (np.arange(0, grid_w, step) + 0.5) * gdx
    ys_g = gy0 + (np.arange(0, grid_h, step) + 0.5) * gdy
    # Stagger current arrows 10px north so they don't overlap wind barbs or wave arrows
    _pm = EARTH_CIRC / ((1 << z) * TILE)   # metres per screen pixel at this zoom
    ys_g = ys_g + 10.0 * _pm
    UU = u_raw[::step, ::step]   # m/s eastward
    VV = v_raw[::step, ::step]   # m/s northward
    VM = valid_raw[::step, ::step]
    Xg, Yg = np.meshgrid(xs_g, ys_g)
    Ka = VM & np.isfinite(UU) & np.isfinite(VV)
    tx0, ty0, tx1, ty1 = _btiles(x_min, y_min, x_max, y_max, z)
    n_tx = tx1 - tx0 + 1
    overhead = 3
    max_strip_tiles_h = max(1, (max_strip_mb * 1024 * 1024) //
                            ((n_tx + 4) * TILE * TILE * 4 * overhead) - 2)
    sh = min(max_strip_tiles_h, max(1, ty1 - ty0 + 1))
    print(f"z{z}: {n_tx}x{ty1-ty0+1} tiles, step={step}, strips of {sh} rows (currents)",
          file=sys.stderr, flush=True)
    n_tiles = 0
    def _lat_to_tile_y(lat, zoom):
        lat = max(min(lat, 85.0511), -85.0511)
        rlat = math.radians(lat)
        n = 1 << zoom
        y = (1.0 - math.log(math.tan(rlat) + 1.0 / math.cos(rlat)) / math.pi) / 2.0
        return int(max(0, min(n - 1, math.floor(y * n))))

    strip_starts = list(range(ty0, ty1 + 1, sh))
    if abs(center_lat) > 0.0001:
        center_ty = _lat_to_tile_y(center_lat, z)

        def _strip_dist(s0):
            s1 = min(s0 + sh - 1, ty1)
            smid = (s0 + s1) // 2
            return abs(smid - center_ty)

        strip_starts.sort(key=_strip_dist)

    for s_ty0 in strip_starts:
        s_ty1 = min(s_ty0 + sh - 1, ty1)
        p_tx0 = max(0, tx0-1);  p_tx1 = min((1<<z)-1, tx1+1)
        p_ty0 = max(0, s_ty0-1); p_ty1 = min((1<<z)-1, s_ty1+1)
        bxlo, _, _, byhi = _tb(p_tx0, p_ty0, z)
        _, _, bxhi, _    = _tb(p_tx1, p_ty0, z)
        _, bylo, _, _    = _tb(p_tx0, p_ty1, z)
        fw = (p_tx1 - p_tx0 + 1) * TILE
        fh = (p_ty1 - p_ty0 + 1) * TILE
        K = Ka & (Xg >= bxlo) & (Xg <= bxhi) & (Yg >= bylo) & (Yg <= byhi)
        fig = Figure(figsize=(fw/100., fh/100.), dpi=100)
        canvas = FigureCanvasAgg(fig)
        ax = fig.add_axes([0,0,1,1])
        ax.set_facecolor((0,0,0,0)); fig.patch.set_alpha(0)
        ax.set_xlim(bxlo, bxhi); ax.set_ylim(bylo, byhi)
        ax.axis("off")
        if np.any(K):
            spd = np.sqrt(UU[K]**2 + VV[K]**2)       # m/s
            spd_kts = spd * 1.94384449
            # Uniform-length arrows — color encodes speed (Baltic range 0-2.5 kts).
            # Direction is the only other visual variable, so arrows stay uncluttered
            # at the grid density used for Baltic/North Sea sailing.
            norm = np.maximum(spd, 1e-6)
            un = UU[K] / norm
            vn = VV[K] / norm
            # dots-units: scale=1/(scale*20) → 20 px per unit arrow at scale=1
            q_scale = 1.0 / (scale * 20.0)
            # Colour ramp tuned for 0-2.5 kt Baltic range:
            #   pale sky-blue  (0 kt)  → cornflower (0.5 kt)
            #   → royal blue (1 kt)    → deep navy  (1.75 kt)
            #   → crimson    (≥2.5 kt, rare)
            from matplotlib.colors import LinearSegmentedColormap, Normalize
            cmap_curr = LinearSegmentedColormap.from_list("current", [
                (0.00, (0.60, 0.80, 0.95)),
                (0.20, (0.25, 0.50, 0.90)),
                (0.40, (0.05, 0.25, 0.70)),
                (0.70, (0.03, 0.10, 0.45)),
                (1.00, (0.72, 0.05, 0.15)),
            ])
            vmax_kts = 2.5
            # White halo pass for legibility over chart background
            ax.quiver(Xg[K], Yg[K], un, vn,
                      color=(1, 1, 1, 0.70),
                      units='dots', scale=q_scale,
                      width=3.8, headwidth=5.0, headlength=6.0,
                      pivot='mid')
            # Colour-coded fill — C array drives the colormap
            ax.quiver(Xg[K], Yg[K], un, vn, spd_kts,
                      cmap=cmap_curr, norm=Normalize(vmin=0.0, vmax=vmax_kts),
                      alpha=0.88,
                      units='dots', scale=q_scale,
                      width=2.2, headwidth=3.8, headlength=4.8,
                      pivot='mid')
        canvas.draw()
        buf = np.asarray(canvas.buffer_rgba()).copy()
        del fig, canvas
        for ty in range(s_ty0, s_ty1 + 1):
            row = (ty - p_ty0) * TILE
            for tx in range(tx0, tx1 + 1):
                col = (tx - p_tx0) * TILE
                pix = buf[row:row+TILE, col:col+TILE]
                if pix.shape[0] < TILE or pix.shape[1] < TILE: continue
                if pix[:,:,3].max() == 0: continue
                b = io.BytesIO()
                Image.fromarray(pix,"RGBA").save(b,"PNG",optimize=True)
                tms_y = ((1<<z)-1) - ty
                conn.execute("INSERT OR REPLACE INTO tiles VALUES(?,?,?,?)",
                             (z, tx, tms_y, sqlite3.Binary(b.getvalue())))
                n_tiles += 1
        conn.commit()
        del buf
    import gc; gc.collect()
    conn.close()
    return z, n_tiles, temp_db_path


u_path, v_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
arrow_px_spacing = max(4, int(sys.argv[4]))
scale = max(0.1, float(sys.argv[5]))
zoom_min = int(sys.argv[6])
zoom_max = int(sys.argv[7])
max_strip_mb = int(sys.argv[8])
n_workers = max(1, int(sys.argv[9]))
center_lat = float(sys.argv[10]) if len(sys.argv) > 10 and sys.argv[10] else 0.0
center_lon = float(sys.argv[11]) if len(sys.argv) > 11 and sys.argv[11] else 0.0

u_ds = gdal.Open(u_path)
v_ds = gdal.Open(v_path)
if u_ds is None or v_ds is None:
    raise SystemExit("unable to open current u/v rasters")
u_raw = u_ds.GetRasterBand(1).ReadAsArray().astype("float32")
v_raw = v_ds.GetRasterBand(1).ReadAsArray().astype("float32")
if u_raw.shape != v_raw.shape:
    raise SystemExit("u/v raster dimensions do not match")
valid_raw = (u_ds.GetRasterBand(2).ReadAsArray() > 0) if u_ds.RasterCount >= 2 \
            else np.ones(u_raw.shape, bool)
valid_raw &= np.isfinite(u_raw) & np.isfinite(v_raw)
gt = list(u_ds.GetGeoTransform())
u_ds = v_ds = None

grid_h, grid_w = u_raw.shape
gx0, gdx, _, gy0, _, gdy = gt
x_min = min(gx0, gx0 + grid_w * gdx)
x_max = max(gx0, gx0 + grid_w * gdx)
y_min = min(gy0, gy0 + grid_h * gdy)
y_max = max(gy0, gy0 + grid_h * gdy)

conn = sqlite3.connect(out_path)
conn.execute("PRAGMA journal_mode=WAL")
conn.execute("CREATE TABLE IF NOT EXISTS metadata(name TEXT PRIMARY KEY,value TEXT)")
conn.execute("CREATE TABLE IF NOT EXISTS tiles("
             "zoom_level INT,tile_column INT,tile_row INT,tile_data BLOB,"
             "PRIMARY KEY(zoom_level,tile_column,tile_row))")
conn.execute("DELETE FROM metadata")
conn.execute("DELETE FROM tiles")
conn.commit()

zoom_levels = list(range(zoom_min, zoom_max + 1))
actual_workers = min(n_workers, len(zoom_levels))
print(f"Rendering current arrows z{zoom_min}-{zoom_max} with {actual_workers} worker(s)",
      file=sys.stderr)

ctx = multiprocessing.get_context("fork")
with ctx.Pool(processes=actual_workers) as pool:
    results = pool.starmap(_render_arrow_zoom, [
        (z, u_raw, v_raw, valid_raw, gt,
         arrow_px_spacing, scale, max_strip_mb,
         out_path + f".z{z}.tmp",
         x_min, x_max, y_min, y_max, center_lat, center_lon)
        for z in zoom_levels
    ])

n_tiles_total = 0
for z_done, n_z, temp_db in results:
    src = sqlite3.connect(temp_db)
    rows = src.execute(
        "SELECT zoom_level,tile_column,tile_row,tile_data FROM tiles"
    ).fetchall()
    conn.executemany("INSERT OR REPLACE INTO tiles VALUES(?,?,?,?)", rows)
    conn.commit()
    src.close()
    os.unlink(temp_db)
    n_tiles_total += n_z
    print(f"z{z_done}: merged {n_z} tiles", file=sys.stderr)

def m2ll(x, y):
    return (math.degrees(x/6378137),
            math.degrees(2*math.atan(math.exp(y/6378137))-math.pi/2))
lon0,lat0 = m2ll(x_min,y_min); lon1,lat1 = m2ll(x_max,y_max)
conn.executemany("INSERT OR REPLACE INTO metadata VALUES(?,?)",[
    ("name","weather-current-arrows"),("description","weather-current-arrows"),
    ("type","overlay"),("format","png"),
    ("minzoom",str(zoom_min)),("maxzoom",str(zoom_max)),
    ("bounds",f"{lon0:.6f},{lat0:.6f},{lon1:.6f},{lat1:.6f}"),
    ("version","1.1"),])
conn.commit(); conn.close()
print(f"current arrows: {n_tiles_total} tiles z{zoom_min}-{zoom_max}", file=sys.stderr)
PY

    if [[ ! -s "${tmp}" ]]; then
        echo "Generated MBTiles is empty for ${target}, aborting" >&2
        exit 1
    fi

    if [[ -f "${target}" ]] && cmp -s "${target}" "${tmp}"; then
        echo "Overlay unchanged for ${target} — nothing to do."
        rm -f "${tmp}"
        return 1
    fi

    mv -f "${tmp}" "${target}"
    chmod 0644 "${target}"
    echo "Updated ${target}."
    return 0
}

render_current_style() {
    local icon_date="$1"
    local icon_cycle="$2"
    local uo_tif vo_tif current_target nc_file

    if [[ -z "${CMEMS_USERNAME:-}" || -z "${CMEMS_PASSWORD:-}" ]]; then
        echo "Skipping current arrows: CMEMS_USERNAME/CMEMS_PASSWORD not set." >&2
        return 1
    fi

    uo_tif="${WORK_DIR}/current-uo.warp.tif"
    vo_tif="${WORK_DIR}/current-vo.warp.tif"
    nc_file="${WORK_DIR}/current-cmems.nc"
    current_target="${CHART_DIR}/${WEATHER_PREFIX}current-arrows${WEATHER_SUFFIX}.mbtiles"

    # Download CMEMS NetCDF for the valid time of this forecast step.
    python3 - "${icon_date}" "${icon_cycle}" "${FORECAST_HOUR}" \
        "${CMEMS_USERNAME}" "${CMEMS_PASSWORD}" \
        "${CMEMS_DATASET}" "${BBOX}" "${nc_file}" <<'PY'
import os, sys
from datetime import datetime, timedelta, timezone

icon_date, icon_cycle, fh_str = sys.argv[1], sys.argv[2], sys.argv[3]
username, password = sys.argv[4], sys.argv[5]
dataset_id, bbox_str, nc_file = sys.argv[6], sys.argv[7], sys.argv[8]

run_dt = datetime.strptime(icon_date + icon_cycle, "%Y%m%d%H").replace(tzinfo=timezone.utc)
valid_dt = run_dt + timedelta(hours=int(fh_str))
valid_str = valid_dt.strftime("%Y-%m-%dT%H:00:00")
lon_min, lat_min, lon_max, lat_max = [float(x) for x in bbox_str.split(",")]

try:
    import copernicusmarine
except ImportError:
    raise SystemExit(
        "copernicusmarine package not found; install with: pip install copernicusmarine"
    )

print(f"Downloading CMEMS {dataset_id} for {valid_str}...", file=sys.stderr)
try:
    copernicusmarine.subset(
        dataset_id=dataset_id,
        variables=["uo", "vo"],
        minimum_longitude=lon_min - 0.1,
        maximum_longitude=lon_max + 0.1,
        minimum_latitude=lat_min - 0.1,
        maximum_latitude=lat_max + 0.1,
        minimum_depth=0.0,
        maximum_depth=1.5,
        start_datetime=valid_str,
        end_datetime=valid_str,
        output_filename=nc_file,
        force_download=True,
        username=username,
        password=password,
    )
except Exception as exc:
    raise SystemExit(f"CMEMS download failed: {exc}")

if not os.path.exists(nc_file):
    raise SystemExit("CMEMS download produced no output file")
print(f"CMEMS data written to {nc_file}", file=sys.stderr)
PY

    local dl_rc=$?
    if [[ "${dl_rc}" -ne 0 ]]; then
        echo "CMEMS download failed (rc=${dl_rc}), skipping current arrows." >&2
        rm -f "${nc_file}"
        return 1
    fi

    # Extract each variable band and warp to EPSG:3857 matching ICON-D2 bbox.
    local uo_raw="${WORK_DIR}/current-uo.raw.tif"
    local vo_raw="${WORK_DIR}/current-vo.raw.tif"
    gdal_translate -of GTiff -b 1 "NETCDF:${nc_file}:uo" "${uo_raw}"
    gdal_translate -of GTiff -b 1 "NETCDF:${nc_file}:vo" "${vo_raw}"
    rm -f "${nc_file}"
    warp_grib "${uo_raw}" "${uo_tif}"
    warp_grib "${vo_raw}" "${vo_tif}"
    rm -f "${uo_raw}" "${vo_raw}"

    local rc=0
    build_current_arrows "${uo_tif}" "${vo_tif}" "${current_target}" || rc=$?
    rm -f "${uo_tif}" "${vo_tif}"
    return ${rc}
}

# Incrementally add a rendered forecast hour to weather-meta.json so the
# panel can display it immediately, without waiting for the full run to finish.
publish_hour() {
    local run_id="$1"
    local fh_int="$2"
    local meta_path
    meta_path="${CHART_DIR%/*}/user/viewer/weather-meta.json"
    [[ -f "${meta_path}" ]] || return 0
    python3 - "${meta_path}" "${run_id}" "${fh_int}" <<'PY'
import json, os, sys
from datetime import datetime, timezone
path, run_id, fh = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    with open(path) as f:
        m = json.load(f)
except Exception:
    m = {"runs": []}
found = False
for r in m.get("runs", []):
    if r["id"] == run_id:
        h = r.setdefault("hours", [])
        if fh not in h:
            h.append(fh)
            h.sort()
        found = True
        break
if not found:
    rdt = datetime.strptime(run_id, "%Y%m%d%H").replace(tzinfo=timezone.utc)
    m.setdefault("runs", []).append({
        "id": run_id,
        "label": rdt.strftime("%d %b %H") + "Z",
        "run_utc": rdt.strftime("%Y-%m-%dT%H:%MZ"),
        "hours": [fh],
    })
    m["runs"].sort(key=lambda r: r["id"])
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(m, f, indent=2)
os.replace(tmp, path)
PY
}

run_layer_render() {
    local layer="$1"
    local changed=1

    case "${layer}" in
        wind_style)
            render_wind_style "${ICON_DATE}" "${ICON_CYCLE}" || changed=0
            ;;
        wind_speed_10m)
            render_wind_style "${ICON_DATE}" "${ICON_CYCLE}" || changed=0
            ;;
        wind_barbs)
            render_wind_style "${ICON_DATE}" "${ICON_CYCLE}" || changed=0
            ;;
        wind_u_10m)
            render_icon_overlay u_10m u_10m wind-u_10m "${ICON_DATE}" "${ICON_CYCLE}" || changed=0
            ;;
        wind_v_10m)
            render_icon_overlay v_10m v_10m wind-v_10m "${ICON_DATE}" "${ICON_CYCLE}" || changed=0
            ;;
        temperature_2m)
            render_icon_overlay t_2m t_2m temperature-t_2m "${ICON_DATE}" "${ICON_CYCLE}" || changed=0
            ;;
        precipitation_total)
            render_icon_overlay tot_prec tot_prec precipitation-tot_prec "${ICON_DATE}" "${ICON_CYCLE}" || changed=0
            ;;
        precipitation)
            render_icon_overlay tot_prec tot_prec precipitation-tot_prec "${ICON_DATE}" "${ICON_CYCLE}" || changed=0
            ;;
        pressure_msl)
            render_icon_overlay pmsl pmsl pressure-pmsl "${ICON_DATE}" "${ICON_CYCLE}" || changed=0
            ;;
        pmsl)
            render_icon_overlay pmsl pmsl pressure-pmsl "${ICON_DATE}" "${ICON_CYCLE}" || changed=0
            ;;
        wave_style)
            if [[ -n "${DMI_WAVE_DATE:-}" ]] && \
               render_dmi_wave_style "${DMI_WAVE_DATE}" "${DMI_WAVE_CYCLE}"; then
                :
            else
                echo "DMI WAM unavailable for +${FORECAST_HOUR}h; falling back to DWD EWAM." >&2
                render_wave_style "${WAVE_DATE}" "${WAVE_CYCLE}" || changed=0
            fi
            ;;
        wave_height)
            render_wave_overlay "${WAVE_DATE}" "${WAVE_CYCLE}" || changed=0
            ;;
        current_style)
            if [[ -n "${DMI_DKSS_DATE:-}" ]] && \
               render_dmi_current_style "${DMI_DKSS_DATE}" "${DMI_DKSS_CYCLE}"; then
                :
            else
                echo "DMI DKSS unavailable for +${FORECAST_HOUR}h; falling back to CMEMS." >&2
                render_current_style "${ICON_DATE}" "${ICON_CYCLE}" || changed=0
            fi
            ;;
        sigmet)
            echo "Skipping sigmet: no machine-readable SIGMET overlay source is configured." >&2
            changed=0
            ;;
        *)
            echo "Unknown layer '${layer}' — skipping" >&2
            changed=0
            ;;
    esac

    return "${changed}"
}

read -r ICON_DATE ICON_CYCLE <<< "$(find_recent_icon_cycle)" || {
    echo "Could not resolve a recent ICON-D2 cycle." >&2
    exit 1
}
read -r WAVE_DATE WAVE_CYCLE <<< "$(find_recent_ewam_cycle)" || {
    echo "Could not resolve a recent EWAM wave cycle." >&2
    exit 1
}

DMI_DKSS_DATE="" DMI_DKSS_CYCLE=""
if read -r DMI_DKSS_DATE DMI_DKSS_CYCLE <<< "$(find_recent_dmi_dkss_cycle 2>/dev/null)"; then
    echo "DMI DKSS cycle: ${DMI_DKSS_DATE} ${DMI_DKSS_CYCLE}Z"
else
    echo "Could not resolve DMI DKSS cycle; currents will fall back to CMEMS." >&2
fi

DMI_WAVE_DATE="" DMI_WAVE_CYCLE=""
if read -r DMI_WAVE_DATE DMI_WAVE_CYCLE <<< "$(find_recent_dmi_wam_cycle 2>/dev/null)"; then
    echo "DMI WAM cycle: ${DMI_WAVE_DATE} ${DMI_WAVE_CYCLE}Z"
else
    echo "Could not resolve DMI WAM cycle; waves will fall back to DWD EWAM." >&2
fi

RUN_ID="${ICON_DATE}${ICON_CYCLE}"

# Resolve boat position once so strip rendering can prioritize nearby tiles.
fetch_boat_position

IFS=',' read -r -a requested_layers <<< "${LAYERS}"
layer_count=0
for layer in "${requested_layers[@]}"; do
    layer="${layer//[[:space:]]/}"
    [[ -n "${layer}" ]] && layer_count=$((layer_count + 1))
done
(( layer_count < 1 )) && layer_count=1

if [[ "${LAYER_PARALLEL_WORKERS}" == "auto" ]]; then
    cpu_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)"
    [[ "${cpu_count}" =~ ^[0-9]+$ ]] || cpu_count=1
    (( cpu_count < 1 )) && cpu_count=1

    mem_avail_kb="$(awk '/MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)"
    if [[ "${mem_avail_kb}" =~ ^[0-9]+$ ]] && (( mem_avail_kb > 0 )); then
        mem_avail_mb=$(( mem_avail_kb / 1024 ))
        mem_based_jobs=$(( (mem_avail_mb - 256) / (WIND_BARB_STRIP_MB + 120) ))
        (( mem_based_jobs < 1 )) && mem_based_jobs=1
    else
        mem_based_jobs=${cpu_count}
    fi

    max_layer_jobs=${layer_count}
    (( max_layer_jobs > cpu_count )) && max_layer_jobs=${cpu_count}
    (( max_layer_jobs > mem_based_jobs )) && max_layer_jobs=${mem_based_jobs}
    (( max_layer_jobs < 1 )) && max_layer_jobs=1

    echo "LAYER_PARALLEL_WORKERS=auto -> ${max_layer_jobs} (layers=${layer_count}, cpu=${cpu_count}, mem-based=${mem_based_jobs})"
elif [[ ! "${LAYER_PARALLEL_WORKERS}" =~ ^[0-9]+$ ]] || (( 10#${LAYER_PARALLEL_WORKERS} < 1 )); then
    echo "LAYER_PARALLEL_WORKERS must be an integer >= 1 or 'auto', got '${LAYER_PARALLEL_WORKERS}'; using 1." >&2
    max_layer_jobs=1
else
    max_layer_jobs=$((10#${LAYER_PARALLEL_WORKERS}))
fi

updated_any=0
IFS=',' read -r -a fh_list <<< "${FORECAST_HOURS}"

for fh in "${fh_list[@]}"; do
    FORECAST_HOUR="${fh//[[:space:]]/}"
    WEATHER_SUFFIX="-${RUN_ID}+${FORECAST_HOUR}"
    echo "--- Forecast hour +${FORECAST_HOUR} (${WEATHER_SUFFIX}) ---"

    hour_published=0
    pids=()
    for layer in "${requested_layers[@]}"; do
        layer="${layer//[[:space:]]/}"
        [[ -z "${layer}" ]] && continue

        (
            run_layer_render "${layer}" || true
        ) &
        pids+=("$!")

        while (( ${#pids[@]} >= max_layer_jobs )); do
            wait -n || true
            active_pids=()
            for pid in "${pids[@]}"; do
                if kill -0 "${pid}" 2>/dev/null; then
                    active_pids+=("${pid}")
                fi
            done
            pids=("${active_pids[@]}")
            if (( hour_published == 0 )) && compgen -G "${CHART_DIR}/${WEATHER_PREFIX}*${WEATHER_SUFFIX}.mbtiles" >/dev/null; then
                publish_hour "${RUN_ID}" "$((10#${FORECAST_HOUR}))"
                hour_published=1
            fi
        done
    done

    for pid in "${pids[@]}"; do
        wait "${pid}" || true
        if (( hour_published == 0 )) && compgen -G "${CHART_DIR}/${WEATHER_PREFIX}*${WEATHER_SUFFIX}.mbtiles" >/dev/null; then
            publish_hour "${RUN_ID}" "$((10#${FORECAST_HOUR}))"
            hour_published=1
        fi
    done

    if compgen -G "${CHART_DIR}/${WEATHER_PREFIX}*${WEATHER_SUFFIX}.mbtiles" >/dev/null; then
        updated_any=1
        if (( hour_published == 0 )); then
            publish_hour "${RUN_ID}" "$((10#${FORECAST_HOUR}))"
        fi
    fi
done

if [[ "${updated_any}" -eq 1 ]]; then
    # ---------------------------------------------------------------
    # Symlinks: create/update stable names that AvNav always knows.
    # Each stable name (e.g. weather-wind-barbs.mbtiles) is a symlink
    # pointing to the latest run's first forecast hour.
    # ---------------------------------------------------------------
    first_fh="${fh_list[0]//[[:space:]]/}"
    first_suffix="-${RUN_ID}+${first_fh}"
    for src in "${CHART_DIR}/${WEATHER_PREFIX}"*"${first_suffix}.mbtiles"; do
        [[ -f "${src}" ]] || continue
        src_base="$(basename "${src}")"
        # stable_name = strip the run+fh suffix, e.g. weather-wind-barbs.mbtiles
        stable="${src_base%${first_suffix}.mbtiles}.mbtiles"
        # skip if the stable name IS the source (no suffix was added somehow)
        [[ "${stable}" == "${src_base}" ]] && continue
        ln -sf "${src_base}" "${CHART_DIR}/${stable}"
        echo "Symlink: ${stable} -> ${src_base}"
    done

    # ---------------------------------------------------------------
    # .cfg files: only for the stable symlink names, not timestamped.
    # ---------------------------------------------------------------
    for mbtiles_path in "${CHART_DIR}/${WEATHER_PREFIX}"*.mbtiles; do
        [[ -L "${mbtiles_path}" ]] || [[ -f "${mbtiles_path}" ]] || continue
        # Skip timestamped files (contain a '+' in the name)
        [[ "$(basename "${mbtiles_path}")" == *+* ]] && continue
        base="$(basename "${mbtiles_path}" .mbtiles)"
        cfg_path="${CHART_DIR}/int@${base}.mbtiles.cfg"
        if [[ ! -f "${cfg_path}" ]]; then
            cat > "${cfg_path}" <<EOF
{
  "useDefault": true,
  "name": "int@${base}",
  "overlays": [
    {
      "name": "int@${base}.mbtiles",
      "displayName": "${base}",
      "type": "overlay",
      "opacity": 0.7,
      "enabled": true,
      "bucket": "H2"
    }
  ],
  "defaultsOverride": {}
}
EOF
            echo "Created overlay config: ${cfg_path}"
        fi
    done

    # ---------------------------------------------------------------
    # Cleanup: delete MBTiles from runs older than KEEP_RUNS.
    # Run IDs are YYYYMMDDHH strings; sort lexicographically.
    # ---------------------------------------------------------------
    mapfile -t all_runs < <(
        find "${CHART_DIR}" -maxdepth 1 -name "${WEATHER_PREFIX}*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]+*.mbtiles" \
            | grep -oP '(?<=-)[0-9]{10}(?=\+)' | sort -u
    )
    if (( ${#all_runs[@]} > KEEP_RUNS )); then
        old_runs=("${all_runs[@]:0:$((${#all_runs[@]} - KEEP_RUNS))}")
        for old_run in "${old_runs[@]}"; do
            echo "Removing old run ${old_run}..."
            find "${CHART_DIR}" -maxdepth 1 -name "${WEATHER_PREFIX}*-${old_run}+*.mbtiles" -delete
        done
    fi

    # ---------------------------------------------------------------
    # Write weather-meta.json for the user.js weather panel.
    # ---------------------------------------------------------------
    meta_dir="${CHART_DIR%/*}/user/viewer"
    mkdir -p "${meta_dir}"
    python3 - "${ICON_DATE}" "${ICON_CYCLE}" \
              "${WAVE_DATE}" "${WAVE_CYCLE}" \
              "${FORECAST_HOURS}" \
              "${CHART_DIR}" "${WEATHER_PREFIX}" \
              "${meta_dir}/weather-meta.json" <<'PY'
import json, os, re, sys
from datetime import datetime, timedelta, timezone

def utc(ymd, cyc):
    return datetime.strptime(ymd + cyc, "%Y%m%d%H").replace(tzinfo=timezone.utc)

icon_date, icon_cyc = sys.argv[1], sys.argv[2]
wave_date, wave_cyc = sys.argv[3], sys.argv[4]
fh_list = [h.strip() for h in sys.argv[5].split(",") if h.strip()]
chart_dir, prefix, out_path = sys.argv[6], sys.argv[7], sys.argv[8]

run_dt = utc(icon_date, icon_cyc)
run_id = icon_date + icon_cyc

# Discover all run IDs on disk
run_ids = sorted(set(
    m.group(1) for f in os.listdir(chart_dir)
    for m in [re.search(r'-([0-9]{10})\+', f)] if m
))

runs = []
for rid in run_ids:
    rdt = datetime.strptime(rid, "%Y%m%d%H").replace(tzinfo=timezone.utc)
    # which forecast hours actually have files on disk for this run?
    available_fhs = sorted(set(
        m.group(1) for f in os.listdir(chart_dir)
        for m in [re.search(r'-' + rid + r'\+([0-9]{3})\.mbtiles$', f)] if m
    ))
    runs.append({
        "id": rid,
        "label": rdt.strftime("%d %b %H") + "Z",
        "run_utc": rdt.strftime("%Y-%m-%dT%H:%MZ"),
        "hours": [int(h) for h in available_fhs],
    })

# Active = most recent run, first hour
active_run = run_id
active_hour = int(fh_list[0]) if fh_list else 3

# Try to preserve previously active state
existing = {}
if os.path.exists(out_path):
    try:
        with open(out_path) as f: existing = json.load(f)
    except Exception: pass
if existing.get("active_run") in [r["id"] for r in runs]:
    active_run = existing["active_run"]
if existing.get("active_hour") in (runs[0]["hours"] if runs else []):
    active_hour = existing["active_hour"]

data = {
    "model": "ICON-D2",
    "updated_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ"),
    "active_run": active_run,
    "active_hour": active_hour,
    "runs": runs,
    "layers": [
        {"id": "wind-barbs",       "label": "Wind barbs"},
        {"id": "wave-height",      "label": "Wave height"},
        {"id": "wave-direction",   "label": "Wave direction"},
        {"id": "current-arrows",   "label": "Currents"},
    ],
    "active_layers": existing.get("active_layers",
                                   ["wind-barbs", "wave-height", "wave-direction"]),
    "chart_prefix": prefix,
}
with open(out_path, "w") as f:
    json.dump(data, f, indent=2)
print(f"Weather meta written: {out_path} ({len(runs)} runs, {len(fh_list)} hours)")
PY

    if systemctl is-active --quiet avnav.service; then
        echo "Restarting avnav.service to pick up updated weather overlays..."
        systemctl restart avnav.service
    fi
fi
