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

# ── stop running seabird services before updating quadlets ───────────────────

if systemctl is-active --quiet seabird-services.target 2>/dev/null; then
    echo "Stopping seabird-services.target before updating quadlets..."
    systemctl stop seabird-services.target
elif systemctl list-units --state=active --no-legend 2>/dev/null | grep -qE "caddy|influxdb|signalk|grafana|homepage|pihole|navidrome|nextcloud-pod"; then
    echo "Stopping individual seabird services before updating quadlets..."
    for svc in caddy influxdb signalk grafana homepage pihole navidrome nextcloud-pod; do
        systemctl stop "${svc}.service" 2>/dev/null || true
    done
fi

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
    /srv/seabird/navidrome
    /srv/seabird/music
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

# ── runtime state dir (/run/seabird) via tmpfiles.d ──────────────────────────
# The caddy container mounts /run/seabird; it must exist before caddy starts.
install -m 0644 config/tmpfiles.d/seabird.conf /etc/tmpfiles.d/seabird.conf
systemd-tmpfiles --create /etc/tmpfiles.d/seabird.conf

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

# ── nextcloud.env — auto-generate secrets on first install ──────────────────

NEXTCLOUD_ENV="/etc/seabird/nextcloud.env"
if [[ ! -s "${NEXTCLOUD_ENV}" ]]; then
    NC_DB_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
    NC_ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
    cat > "${NEXTCLOUD_ENV}" <<EOF
POSTGRES_PASSWORD=${NC_DB_PASSWORD}
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=${NC_ADMIN_PASSWORD}
EOF
    chmod 0600 "${NEXTCLOUD_ENV}"
    echo "  generated /etc/seabird/nextcloud.env with random passwords"
    echo "  !! Save these credentials — they are only shown once !!"
    echo "    Nextcloud admin user     : admin"
    echo "    Nextcloud admin password : ${NC_ADMIN_PASSWORD}"
    echo "    Nextcloud DB password    : ${NC_DB_PASSWORD}"
else
    echo "  /etc/seabird/nextcloud.env already exists and is non-empty — skipping"
fi

# ── remaining env stubs (touch-only if missing) ───────────────────────────────

for f in grafana.env; do
    dest="/etc/seabird/${f}"
    if [[ ! -f "${dest}" ]]; then
        touch "${dest}"
        chmod 0600 "${dest}"
        echo "  created empty ${dest} — populate before starting services"
    fi
done

# ── pihole.env — auto-generate password on first install ─────────────────────
PIHOLE_ENV="/etc/seabird/pihole.env"
if [[ ! -f "${PIHOLE_ENV}" ]]; then
    PIHOLE_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
    printf 'WEBPASSWORD=%s\nTZ=UTC\n' "${PIHOLE_PASSWORD}" > "${PIHOLE_ENV}"
    chmod 0600 "${PIHOLE_ENV}"
    echo "  generated /etc/seabird/pihole.env with random password"
    echo "  !! Save this credential — it is only shown once !!"
    echo "    Pi-hole admin password : ${PIHOLE_PASSWORD}"
elif [[ ! -s "${PIHOLE_ENV}" ]] || ! grep -q 'WEBPASSWORD=' "${PIHOLE_ENV}"; then
    PIHOLE_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)"
    echo "WEBPASSWORD=${PIHOLE_PASSWORD}" >> "${PIHOLE_ENV}"
    chmod 0600 "${PIHOLE_ENV}"
    echo "  added random WEBPASSWORD to existing ${PIHOLE_ENV}"
    echo "  !! Save this credential — it is only shown once !!"
    echo "    Pi-hole admin password : ${PIHOLE_PASSWORD}"
fi

# nextcloud.env is auto-generated above

# ── disable systemd-resolved stub listener (Pi-hole needs port 53) ───────────

echo "Disabling systemd-resolved DNS stub listener (Pi-hole needs port 53)..."
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/90-seabird-no-stub.conf <<'EOF'
[Resolve]
DNSStubListener=no
EOF
systemctl restart systemd-resolved
echo "  resolved stub listener disabled"

# ── avahi mDNS service advertisements ───────────────────────────────────────

echo "Installing avahi service advertisements..."
AVAHI_SRC="${SCRIPT_DIR}/../config/avahi"
mkdir -p /etc/avahi/services
for f in "${AVAHI_SRC}"/*.service; do
    install -m 0644 "${f}" "/etc/avahi/services/$(basename "${f}")"
    echo "  /etc/avahi/services/$(basename "${f}")"
done

# Enable avahi-daemon so seabird.local resolves on the LAN
if ! systemctl is-enabled avahi-daemon &>/dev/null; then
    systemctl enable avahi-daemon
fi
systemctl restart avahi-daemon
echo "  avahi-daemon enabled and running"

# Enable mdns4_minimal in nsswitch so *.local resolves via avahi
if ! grep -q "mdns4_minimal" /etc/nsswitch.conf; then
    sed -i 's/^hosts:.*/hosts:      files mdns4_minimal [NOTFOUND=return] dns myhostname/' /etc/nsswitch.conf
    echo "  nsswitch.conf: mdns4_minimal enabled"
fi

# ── install systemd template units + seabird-services.target ─────────────────

echo "Installing systemd units..."
SYSTEMD_SRC="${SCRIPT_DIR}/../config/systemd"
for unit in seabird-nc-scan@.service seabird-nc-scan@.timer seabird-services.target; do
    install -m 0644 "${SYSTEMD_SRC}/${unit}" "/etc/systemd/system/${unit}"
    echo "  /etc/systemd/system/${unit}"
done

# ── Docker Hub credentials for systemd services ──────────────────────────────
# systemd services run without XDG_RUNTIME_DIR so they cannot find credentials
# stored in /run/user/0/containers/auth.json — copy to the system-wide location.
echo "Checking Docker Hub credentials for systemd services..."
if [[ -f /run/user/0/containers/auth.json ]]; then
    install -m 0600 /run/user/0/containers/auth.json /etc/containers/auth.json
    echo "  credentials copied to /etc/containers/auth.json"
elif [[ ! -s /etc/containers/auth.json ]]; then
    echo "  WARNING: No Docker Hub credentials found."
    echo "  Run 'podman login docker.io' then re-run this script,"
    echo "  or images will be pulled unauthenticated (rate-limited)."
fi

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
echo "  systemctl start caddy influxdb signalk grafana nextcloud-pod homepage pihole navidrome"
echo ""
echo "Add crew users with:"
echo "  scripts/add-user.sh <username>"
