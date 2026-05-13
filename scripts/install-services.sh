#!/usr/bin/env bash
# install-services.sh — install quadlets and initial service configs
#
# Copies quadlet unit files to /etc/containers/systemd/ and initial
# service config to /srv/seabird/ (NVMe), then reloads systemd.
#
# Run after install-storage.sh (NVMe must be mounted).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUADLET_SRC="${SCRIPT_DIR}/../config/quadlets"
CONFIG_SRC="${SCRIPT_DIR}/../config"
QUADLET_DEST="/etc/containers/systemd"

if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root" >&2
    exit 1
fi

# ── check NVMe mounts ─────────────────────────────────────────────────────────

for mp in /srv/seabird/signalk /var/log/journal /var/lib/containers; do
    if ! mountpoint -q "${mp}"; then
        echo "error: ${mp} is not mounted — run install-storage.sh first" >&2
        exit 1
    fi
done

# ── install quadlets ──────────────────────────────────────────────────────────

echo "Installing quadlets to ${QUADLET_DEST}..."
mkdir -p "${QUADLET_DEST}"
install -m 0644 "${QUADLET_SRC}"/*.container "${QUADLET_DEST}/"
install -m 0644 "${QUADLET_SRC}"/*.pod       "${QUADLET_DEST}/" 2>/dev/null || true
echo "  $(ls "${QUADLET_SRC}"/*.container "${QUADLET_SRC}"/*.pod 2>/dev/null | wc -l) unit files installed"

# ── create NVMe data directories ─────────────────────────────────────────────

echo "Creating service data directories on NVMe..."
dirs=(
    /srv/seabird/signalk
    /srv/seabird/influxdb/data
    /srv/seabird/influxdb/config
    /srv/seabird/grafana
    /srv/seabird/nextcloud/html
    /srv/seabird/nextcloud/data
    /srv/seabird/nextcloud/db
    /srv/seabird/homepage
    /srv/seabird/pihole/etc-pihole
    /srv/seabird/pihole/etc-dnsmasq.d
    /srv/seabird/backup
)
for d in "${dirs[@]}"; do
    mkdir -p "${d}"
    echo "  ${d}"
done

# ── install homepage default config (if not already present) ─────────────────

echo "Installing Homepage default config..."
for f in services.yaml settings.yaml; do
    dest="/srv/seabird/homepage/${f}"
    if [[ ! -f "${dest}" ]]; then
        install -m 0644 "${CONFIG_SRC}/homepage/${f}" "${dest}"
        echo "  installed ${f}"
    else
        echo "  ${f} already exists — skipping"
    fi
done

# ── create env file stubs (if not present) ───────────────────────────────────

echo "Creating /etc/seabird env stubs..."
mkdir -p /etc/seabird

# ── influxdb.env — auto-generate secrets on first install ────────────────────

INFLUXDB_ENV="/etc/seabird/influxdb.env"
if [[ ! -f "${INFLUXDB_ENV}" ]]; then
    INFLUXDB_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
    INFLUXDB_TOKEN="$(openssl rand -base64 48 | tr -d '/+=' | head -c 64)"
    cat > "${INFLUXDB_ENV}" <<EOF
DOCKER_INFLUXDB_INIT_PASSWORD=${INFLUXDB_PASSWORD}
DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=${INFLUXDB_TOKEN}
EOF
    chmod 0600 "${INFLUXDB_ENV}"
    echo "  generated /etc/seabird/influxdb.env with random password and token"
    echo "  !! Save these credentials — they are only shown once !!"
    echo "    InfluxDB admin password : ${INFLUXDB_PASSWORD}"
    echo "    InfluxDB admin token    : ${INFLUXDB_TOKEN}"
else
    echo "  /etc/seabird/influxdb.env already exists — skipping"
fi

# ── remaining env stubs (touch-only if missing) ───────────────────────────────

for f in grafana.env nextcloud.env pihole.env; do
    dest="/etc/seabird/${f}"
    if [[ ! -f "${dest}" ]]; then
        touch "${dest}"
        chmod 0600 "${dest}"
        echo "  created empty ${dest} — populate before starting services"
    fi
done

# nextcloud.env needs at minimum POSTGRES_PASSWORD and NEXTCLOUD_ADMIN_*
cat > /etc/seabird/nextcloud.env.example <<'EOF'
POSTGRES_PASSWORD=changeme
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=changeme
EOF

echo "  For Pi-hole, set WEBPASSWORD and TZ in /etc/seabird/pihole.env"
echo "  Example: echo 'WEBPASSWORD=yourpassword' >> /etc/seabird/pihole.env"

# ── disable systemd-resolved stub listener (Pi-hole needs port 53) ───────────

echo "Disabling systemd-resolved DNS stub listener (Pi-hole needs port 53)..."
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/90-seabird-no-stub.conf <<'EOF'
[Resolve]
DNSStubListener=no
EOF
systemctl restart systemd-resolved
echo "  resolved stub listener disabled"

# ── install systemd template units + seabird-services.target ─────────────────

echo "Installing systemd units..."
SYSTEMD_SRC="${SCRIPT_DIR}/../config/systemd"
for unit in seabird-nc-scan@.service seabird-nc-scan@.timer seabird-services.target; do
    install -m 0644 "${SYSTEMD_SRC}/${unit}" "/etc/systemd/system/${unit}"
    echo "  /etc/systemd/system/${unit}"
done

# ── reload systemd to pick up quadlets ───────────────────────────────────────

echo ""
echo "Reloading systemd (quadlet generator)..."
systemctl daemon-reload

echo ""
echo "Services installed."
echo "Start/stop/restart all services:"
echo "  systemctl start   seabird-services.target"
echo "  systemctl stop    seabird-services.target"
echo "  systemctl restart seabird-services.target"
echo ""
echo "Or individually:"
echo "  systemctl start caddy influxdb signalk grafana nextcloud-pod homepage pihole"
echo ""
echo "Add crew users with:"
echo "  scripts/add-user.sh <username>"
