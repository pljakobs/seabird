#!/usr/bin/env bash
# install-services.sh — install quadlets and initial service configs
#
# Copies quadlet unit files to /etc/containers/systemd/ and initial
# service config to /srv/seabird/ (NVMe), then reloads systemd.
#
# Run after install-storage.sh (NVMe must be mounted).
#
# Options:
#   --signalk-nmea-tcp=yes   (default) Enable SignalK NMEA 0183 TCP output on
#                            port 10110. Enables the interface in settings.json
#                            and opens the port in the LAN firewall zone.
#   --signalk-nmea-tcp=no    Disable the NMEA TCP output.

set -euo pipefail

SIGNALK_NMEA_TCP=""   # empty = not yet decided

# ── argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --signalk-nmea-tcp=yes) SIGNALK_NMEA_TCP=yes; shift ;;
        --signalk-nmea-tcp=no)  SIGNALK_NMEA_TCP=no;  shift ;;
        --signalk-nmea-tcp)
            if [[ "${2:-}" == "yes" || "${2:-}" == "no" ]]; then
                SIGNALK_NMEA_TCP="$2"; shift 2
            else
                echo "error: --signalk-nmea-tcp requires 'yes' or 'no'" >&2; exit 1
            fi ;;
        -h|--help)
            sed -n '/^# install-services/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'; exit 0 ;;
        *) echo "error: unknown option '$1'" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUADLET_SRC="${SCRIPT_DIR}/../config/quadlets"
CONFIG_SRC="${SCRIPT_DIR}/../config"
QUADLET_DEST="/etc/containers/systemd"

if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root" >&2
    exit 1
fi

AVNAV_MAC_FILE="/etc/seabird/avnav.mac"

generate_mac() {
    local random_bytes first_octet
    random_bytes="$(openssl rand -hex 6)"
    first_octet="$(( 0x${random_bytes:0:2} ))"
    first_octet="$(( (first_octet & 0xfe) | 0x02 ))"
    printf '%02x:%s:%s:%s:%s:%s\n' \
        "${first_octet}" \
        "${random_bytes:2:2}" \
        "${random_bytes:4:2}" \
        "${random_bytes:6:2}" \
        "${random_bytes:8:2}" \
        "${random_bytes:10:2}"
}

if [[ ! -f "${AVNAV_MAC_FILE}" ]]; then
    mkdir -p "$(dirname "${AVNAV_MAC_FILE}")"
    if [[ -f "${QUADLET_DEST}/avnav.container" ]]; then
        existing_mac="$(grep -Eo 'Network=bridge:mac=[0-9a-f:]{17}' "${QUADLET_DEST}/avnav.container" | head -n1 | cut -d= -f3 || true)"
        if [[ -n "${existing_mac}" ]]; then
            printf '%s\n' "${existing_mac}" > "${AVNAV_MAC_FILE}"
        fi
    fi
    if [[ ! -f "${AVNAV_MAC_FILE}" ]]; then
        generate_mac > "${AVNAV_MAC_FILE}"
    fi
    chmod 0600 "${AVNAV_MAC_FILE}"
    echo "  initialized ${AVNAV_MAC_FILE} with a stable per-host MAC"
else
    echo "  ${AVNAV_MAC_FILE} already exists — reusing stored MAC"
fi

AVNAV_MAC="$(tr -d '\n' < "${AVNAV_MAC_FILE}")"

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
elif systemctl list-units --state=active --no-legend 2>/dev/null | grep -qE "caddy|influxdb|signalk|grafana|homepage|pihole|navidrome|avnav|nextcloud-pod"; then
    echo "Stopping individual seabird services before updating quadlets..."
    for svc in caddy influxdb signalk grafana homepage pihole navidrome avnav nextcloud-pod; do
        systemctl stop "${svc}.service" 2>/dev/null || true
    done
fi

# ── install quadlets ──────────────────────────────────────────────────────────

echo "Installing quadlets to ${QUADLET_DEST}..."
mkdir -p "${QUADLET_DEST}"
for src in "${QUADLET_SRC}"/*.container; do
    dest="${QUADLET_DEST}/$(basename "${src}")"
    if [[ $(basename "${src}") == "avnav.container" ]]; then
        sed "s/__AVNAV_MAC__/${AVNAV_MAC}/g" "${src}" > "${dest}"
        chmod 0644 "${dest}"
    else
        install -m 0644 "${src}" "${dest}"
    fi
done
install -m 0644 "${QUADLET_SRC}"/*.pod       "${QUADLET_DEST}/" 2>/dev/null || true
echo "  $(ls "${QUADLET_SRC}"/*.container "${QUADLET_SRC}"/*.pod 2>/dev/null | wc -l) unit files installed"

# ── create NVMe data directories ─────────────────────────────────────────────

echo "Creating service data directories on NVMe..."
dirs=(
    /srv/seabird/signalk
    /srv/seabird/avnav
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

# SignalK runs as uid/gid 1000 (node) and needs write access for plugins/state.
chown -R 1000:1000 /srv/seabird/signalk
chmod 0755 /srv/seabird/signalk

# ── SignalK: ensure allow_readonly is set in security.json ───────────────────
# Allows unauthenticated read-only access so AvNav can read position/sensor
# data from SignalK without requiring a login token.

SK_SECURITY_JSON="/srv/seabird/signalk/security.json"
if [[ ! -f "${SK_SECURITY_JSON}" ]]; then
    printf '{"allow_readonly":true,"immutableConfig":false}\n' \
        | python3 -m json.tool > "${SK_SECURITY_JSON}"
    chown 1000:1000 "${SK_SECURITY_JSON}"
    echo "  created ${SK_SECURITY_JSON} with allow_readonly=true"
else
    python3 - "${SK_SECURITY_JSON}" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    d = json.load(f)
if d.get("allow_readonly") is not True:
    d["allow_readonly"] = True
    with open(path, "w") as f:
        json.dump(d, f, indent=2)
    print(f"  set allow_readonly=true in {path}")
else:
    print(f"  {path}: allow_readonly already true — skipping")
PYEOF
fi

# ── AvNav: patch avnav_server.xml for SignalK integration ────────────────────
# Sets host="host.containers.internal" (container-to-host routing) and
# decodeData="True" (decodes navigation.position → gps.lat/gps.lon so
# AvNav chart display shows the vessel's position).
# avnav_server.xml is generated by AvNav on first start; this patch is
# idempotent and safe to re-run.

AVNAV_XML="/srv/seabird/avnav/avnav_server.xml"
if [[ -f "${AVNAV_XML}" ]]; then
    python3 - "${AVNAV_XML}" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()

def set_xml_attr(text, elem, attr, value):
    """Add or update a named attribute on a self-closing XML element."""
    def replacer(m):
        tag = m.group(0)
        attr_re = re.compile(rf'\b{re.escape(attr)}="[^"]*"')
        if attr_re.search(tag):
            return attr_re.sub(f'{attr}="{value}"', tag)
        # Insert the attribute before the closing />
        return re.sub(r'(\s*/?>)$', f' {attr}="{value}"\\1', tag)
    return re.sub(rf'<{re.escape(elem)}(?:\s[^>]*)?\s*/>', replacer, text)

orig = content
content = set_xml_attr(content, "AVNSignalKHandler", "host", "host.containers.internal")
content = set_xml_attr(content, "AVNSignalKHandler", "decodeData", "True")
if content != orig:
    with open(path, "w") as f:
        f.write(content)
    print(f"  patched AVNSignalKHandler in {path}")
else:
    print(f"  {path}: AVNSignalKHandler already correct — skipping")
PYEOF
else
    echo "  NOTE: ${AVNAV_XML} not yet created (AvNav has not started yet)."
    echo "  Re-run install-services.sh after AvNav's first start to apply SignalK GPS config."
fi

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

# ── disable DNS on NM shared-mode dnsmasq (Pi-hole owns port 53) ─────────────
# NM's shared mode on crew LAN / WiFi AP runs dnsmasq for DHCP.  Without this,
# that dnsmasq binds port 53 on interface IPs and prevents pihole-FTL from
# binding 0.0.0.0:53.  port=0 disables DNS while leaving DHCP intact; clients
# still get the interface IP (e.g. 10.42.0.1) as their DNS server via DHCP,
# and pihole answers those queries via 0.0.0.0:53.

echo "Installing NM shared-mode dnsmasq DNS-disable config..."
NM_DNSMASQ_DIR="/etc/NetworkManager/dnsmasq-shared.d"
mkdir -p "${NM_DNSMASQ_DIR}"
install -m 0644 "${SCRIPT_DIR}/../config/nm-dnsmasq-shared/10-no-dns.conf" \
    "${NM_DNSMASQ_DIR}/10-no-dns.conf"
echo "  ${NM_DNSMASQ_DIR}/10-no-dns.conf"

# Bounce all shared-mode NM connections so dnsmasq reloads with the new config
while IFS= read -r con; do
    [[ -z "${con}" ]] && continue
    method=$(nmcli -g ipv4.method con show "${con}" 2>/dev/null)
    if [[ "${method}" == "shared" ]]; then
        echo "  bouncing shared connection: ${con}"
        nmcli con down "${con}" 2>/dev/null || true
        sleep 1
        nmcli con up "${con}" 2>/dev/null || true
    fi
done < <(nmcli -t -f NAME con show)
echo "  NM shared-mode dnsmasq DNS disabled"

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

# ── Nextcloud sub-path config ─────────────────────────────────────────────────
# Ensure overwritewebroot and all trusted_domains are set so Nextcloud works
# correctly when served through the Caddy /nextcloud sub-path proxy.
# The file goes into the HTML volume (/srv/seabird/nextcloud/html/config/)
# which is already bind-mounted at /var/www/html inside the container, so no
# extra volume mount is needed.  It is always installed/updated so config
# changes in the repo are picked up on re-runs.

echo "Installing Nextcloud sub-path config..."
NC_CONFIG_DIR="/srv/seabird/nextcloud/html/config"
if [[ -d "${NC_CONFIG_DIR}" ]]; then
    install -m 0644 "${CONFIG_SRC}/nextcloud/zz-seabird.config.php" \
        "${NC_CONFIG_DIR}/zz-seabird.config.php"
    echo "  installed ${NC_CONFIG_DIR}/zz-seabird.config.php"
else
    echo "  ${NC_CONFIG_DIR} not present yet — will be installed on first Nextcloud start"
    echo "  (run install-services.sh again after Nextcloud initialises)"
fi

# ── Cockpit sub-path config ───────────────────────────────────────────────────
# UrlRoot=/cockpit tells Cockpit to prefix all asset and redirect URLs with
# /cockpit so they resolve correctly when proxied via Caddy's handle_path.

echo "Installing Cockpit sub-path config..."
mkdir -p /etc/cockpit
install -m 0644 "${CONFIG_SRC}/cockpit/cockpit.conf" /etc/cockpit/cockpit.conf
echo "  installed /etc/cockpit/cockpit.conf"
if systemctl is-active --quiet cockpit.service 2>/dev/null; then
    systemctl restart cockpit.service
    echo "  cockpit.service restarted"
fi

# ── SignalK NMEA TCP listener (port 10110) ───────────────────────────────────
# The signalk container publishes port 10110 (PublishPort=10110:10110).
# SignalK's built-in nmea-tcp interface outputs NMEA 0183 sentences on that
# port.  This section ensures the interface is enabled in settings.json and
# opens the port in the LAN firewall zone.

SK_SETTINGS="/srv/seabird/signalk/settings.json"

if [[ -z "${SIGNALK_NMEA_TCP}" ]]; then
    # Detect current state from settings.json
    if [[ -f "${SK_SETTINGS}" ]] && \
       python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get('interfaces',{}).get('nmea-tcp') else 1)" "${SK_SETTINGS}" 2>/dev/null; then
        _NMEA_TCP_CURRENT=yes
    else
        _NMEA_TCP_CURRENT=no
    fi

    if [[ -t 0 ]]; then
        echo ""
        if [[ "${_NMEA_TCP_CURRENT}" == yes ]]; then
            echo "SignalK NMEA TCP listener (port 10110) is currently: ENABLED"
        else
            echo "SignalK NMEA TCP listener (port 10110) is currently: DISABLED"
        fi
        echo "  Outputs NMEA 0183 sentences on TCP port 10110 — connect chart plotters"
        echo "  and other NMEA consumers on the LAN directly to seabird:10110."
        read -r -p "Enable NMEA TCP listener? [Y/n]: " _NMEA_TCP_REPLY
        if [[ -z "${_NMEA_TCP_REPLY}" || "${_NMEA_TCP_REPLY}" =~ ^[Yy]$ ]]; then
            SIGNALK_NMEA_TCP=yes
        elif [[ "${_NMEA_TCP_REPLY}" =~ ^[Nn]$ ]]; then
            SIGNALK_NMEA_TCP=no
        else
            SIGNALK_NMEA_TCP="${_NMEA_TCP_CURRENT}"
        fi
    else
        # Non-interactive: default to enabled
        SIGNALK_NMEA_TCP=yes
    fi
fi

if [[ "${SIGNALK_NMEA_TCP}" == yes ]]; then
    echo "Enabling SignalK NMEA TCP listener on port 10110..."
    if [[ -f "${SK_SETTINGS}" ]]; then
        python3 - "${SK_SETTINGS}" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    d = json.load(f)
interfaces = d.setdefault("interfaces", {})
if not interfaces.get("nmea-tcp"):
    interfaces["nmea-tcp"] = True
    with open(path, "w") as f:
        json.dump(d, f, indent=2)
    print(f"  enabled nmea-tcp interface in {path}")
else:
    print(f"  {path}: nmea-tcp already enabled — skipping")
PYEOF
    else
        echo "  WARNING: ${SK_SETTINGS} not yet created (SignalK has not started yet)."
        echo "  Re-run install-services.sh after SignalK's first start to enable NMEA TCP."
    fi
    # Open the port in the LAN zone (idempotent)
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        if ! firewall-cmd --zone=lan --query-port=10110/tcp --permanent &>/dev/null; then
            firewall-cmd --zone=lan --add-port=10110/tcp --permanent
            firewall-cmd --reload
            echo "  opened TCP 10110 in LAN firewall zone"
        else
            echo "  TCP 10110 already open in LAN firewall zone — skipping"
        fi
    fi
elif [[ "${SIGNALK_NMEA_TCP}" == no ]]; then
    echo "Disabling SignalK NMEA TCP listener on port 10110..."
    if [[ -f "${SK_SETTINGS}" ]]; then
        python3 - "${SK_SETTINGS}" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    d = json.load(f)
interfaces = d.get("interfaces", {})
if interfaces.get("nmea-tcp"):
    interfaces["nmea-tcp"] = False
    with open(path, "w") as f:
        json.dump(d, f, indent=2)
    print(f"  disabled nmea-tcp interface in {path}")
else:
    print(f"  {path}: nmea-tcp already disabled — skipping")
PYEOF
    fi
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        if firewall-cmd --zone=lan --query-port=10110/tcp --permanent &>/dev/null; then
            firewall-cmd --zone=lan --remove-port=10110/tcp --permanent
            firewall-cmd --reload
            echo "  removed TCP 10110 from LAN firewall zone"
        fi
    fi
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
echo "  systemctl start caddy influxdb signalk grafana nextcloud-pod homepage pihole navidrome avnav"
echo ""
echo "Add crew users with:"
echo "  scripts/add-user.sh <username>"
