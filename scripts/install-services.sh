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

for f in influxdb.env grafana.env nextcloud.env; do
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

# influxdb.env needs admin token / password
cat > /etc/seabird/influxdb.env.example <<'EOF'
DOCKER_INFLUXDB_INIT_PASSWORD=changeme
DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=changeme-token
EOF

echo "  example files written to /etc/seabird/*.env.example"
echo "  copy and fill in before starting services:"
echo "    cp /etc/seabird/nextcloud.env.example /etc/seabird/nextcloud.env"
echo "    cp /etc/seabird/influxdb.env.example  /etc/seabird/influxdb.env"

# ── install systemd template units ───────────────────────────────────────────

echo "Installing systemd template units..."
SYSTEMD_SRC="${SCRIPT_DIR}/../config/systemd"
for unit in seabird-nc-scan@.service seabird-nc-scan@.timer; do
    install -m 0644 "${SYSTEMD_SRC}/${unit}" "/etc/systemd/system/${unit}"
    echo "  /etc/systemd/system/${unit}"
done

# ── reload systemd to pick up quadlets ───────────────────────────────────────

echo ""
echo "Reloading systemd (quadlet generator)..."
systemctl daemon-reload

echo ""
echo "Services installed. Start them with:"
echo "  systemctl start caddy.service"
echo "  systemctl start signalk.service"
echo "  systemctl start influxdb.service"
echo "  systemctl start grafana.service"
echo "  systemctl start nextcloud-pod.service"
echo "  systemctl start homepage.service"
echo ""
echo "Enable on boot with:"
echo "  systemctl enable caddy signalk influxdb grafana nextcloud-pod homepage"
echo ""
echo "Add crew users with:"
echo "  scripts/add-user.sh <username>"
