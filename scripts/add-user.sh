#!/usr/bin/env bash
# add-user.sh — create a seabird crew user
#
# Creates:
#   - Linux system account with home directory under /home/<user>
#   - Nextcloud account (via occ inside the nextcloud container)
#   - ~/Nextcloud bind-mounted from /srv/seabird/nextcloud/data/<user>/files/
#     so crew files are accessible both via Nextcloud and directly on the host
#   - systemd .mount unit for the bind mount (persists across reboots)
#   - seabird-nc-scan@<user>.timer — hourly occ files:scan so files written
#     directly to ~/Nextcloud appear in the Nextcloud UI
#
# Usage:
#   sudo scripts/add-user.sh <username> [--admin] [--display-name "Full Name"]
#
# Examples:
#   sudo scripts/add-user.sh alice
#   sudo scripts/add-user.sh bob --admin --display-name "Bob Smith"
#
# Re-running for an existing user is safe — all steps check before acting.
#
# Requirements:
#   - install-storage.sh must have run (NVMe mounted)
#   - nextcloud container must be running when this script is first run
#     (needed to create the Nextcloud account via occ)

set -euo pipefail

# ── argument parsing ──────────────────────────────────────────────────────────

USERNAME=""
IS_ADMIN=false
DISPLAY_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --admin)          IS_ADMIN=true; shift ;;
        --display-name)   DISPLAY_NAME="$2"; shift 2 ;;
        -h|--help)
            sed -n '/^# add-user/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        -*)
            echo "error: unknown option '$1'" >&2; exit 1 ;;
        *)
            if [[ -z "${USERNAME}" ]]; then
                USERNAME="$1"
            else
                echo "error: unexpected argument '$1'" >&2; exit 1
            fi
            shift ;;
    esac
done

if [[ -z "${USERNAME}" ]]; then
    echo "error: username required" >&2
    echo "Usage: $0 <username> [--admin] [--display-name \"Full Name\"]" >&2
    exit 1
fi

# Validate username (alphanumeric + hyphen + underscore, no leading hyphen)
if [[ ! "${USERNAME}" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
    echo "error: invalid username '${USERNAME}'" >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root" >&2
    exit 1
fi

# ── helpers ───────────────────────────────────────────────────────────────────

section() { echo; echo "── $* ──"; }
ok()      { echo "  ✓ $*"; }
info()    { echo "  → $*"; }

NC_DATA_DIR="/srv/seabird/nextcloud/data/${USERNAME}/files"
NC_MOUNT_DIR="/home/${USERNAME}/Nextcloud"

# Systemd unit name must encode the path: replace / with - and strip leading -
# /home/alice/Nextcloud → home-alice-Nextcloud.mount
NC_MOUNT_UNIT="home-${USERNAME}-Nextcloud.mount"

# ── 1. Linux user ─────────────────────────────────────────────────────────────

section "Linux user"

if id "${USERNAME}" &>/dev/null; then
    ok "User '${USERNAME}' already exists"
else
    useradd --create-home --shell /bin/bash "${USERNAME}"
    ok "Created Linux user '${USERNAME}'"
    passwd "${USERNAME}"   # prompt for password
fi

# ── 2. Nextcloud user ─────────────────────────────────────────────────────────

section "Nextcloud user"

if ! systemctl is-active --quiet nextcloud.service 2>/dev/null; then
    echo "warning: nextcloud container is not running — skipping Nextcloud account creation" >&2
    echo "         Re-run this script after starting Nextcloud to create the account." >&2
    NC_CREATED=false
else
    NC_OCC="podman exec --user www-data nextcloud php occ"

    if ${NC_OCC} user:list --output=plain 2>/dev/null | grep -qx "${USERNAME}"; then
        ok "Nextcloud user '${USERNAME}' already exists"
    else
        NC_PASSWORD="$(head -c 16 /dev/urandom | base64 | tr -d '/+' | head -c 16)"
        OC_PASS="${NC_PASSWORD}" ${NC_OCC} user:add \
            --password-from-env \
            ${IS_ADMIN:+--group admin} \
            "${USERNAME}"
        if [[ -n "${DISPLAY_NAME}" ]]; then
            ${NC_OCC} user:setting "${USERNAME}" settings display_name "${DISPLAY_NAME}"
        fi
        ok "Created Nextcloud user '${USERNAME}'"
        echo
        echo "  ┌─────────────────────────────────────────────────────────┐"
        echo "  │  Nextcloud initial password for ${USERNAME}:"
        printf  "  │    %-53s│\n" "${NC_PASSWORD}"
        echo "  │  User must change this on first login.                  │"
        echo "  └─────────────────────────────────────────────────────────┘"
    fi
    NC_CREATED=true
fi

# ── 3. Ensure Nextcloud data directory exists ─────────────────────────────────

section "Nextcloud data directory"

# Nextcloud creates this on first login; pre-create it so the bind mount
# can be enabled now even before the user has logged in to Nextcloud.
if [[ ! -d "${NC_DATA_DIR}" ]]; then
    mkdir -p "${NC_DATA_DIR}"
    chown -R "${USERNAME}:${USERNAME}" "$(dirname "${NC_DATA_DIR}")"
    ok "Created ${NC_DATA_DIR}"

    # Inform Nextcloud that the directory was externally created
    if [[ "${NC_CREATED:-false}" == true ]]; then
        podman exec --user www-data nextcloud php occ files:scan "${USERNAME}" \
            --path "${USERNAME}/files" 2>/dev/null || true
    fi
else
    ok "${NC_DATA_DIR} already exists"
fi

# ── 4. ~/Nextcloud mount point ────────────────────────────────────────────────

section "~/Nextcloud mount point"

if [[ ! -d "${NC_MOUNT_DIR}" ]]; then
    mkdir -p "${NC_MOUNT_DIR}"
    chown "${USERNAME}:${USERNAME}" "${NC_MOUNT_DIR}"
    ok "Created ${NC_MOUNT_DIR}"
else
    ok "${NC_MOUNT_DIR} already exists"
fi

# ── 5. Systemd bind mount unit ────────────────────────────────────────────────

section "Systemd bind mount (${NC_MOUNT_UNIT})"

cat > "/etc/systemd/system/${NC_MOUNT_UNIT}" <<EOF
[Unit]
Description=Nextcloud home for ${USERNAME}
Documentation=https://github.com/pjakobs/seabird
After=local-fs.target nextcloud.service
ConditionPathIsDirectory=${NC_DATA_DIR}

[Mount]
What=${NC_DATA_DIR}
Where=${NC_MOUNT_DIR}
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${NC_MOUNT_UNIT}"
ok "Bind mount enabled and active"

# ── 6. Periodic occ files:scan timer ─────────────────────────────────────────

section "Hourly files:scan timer (seabird-nc-scan@${USERNAME}.timer)"

# The template units are deployed by install-services.sh.
# Just enable the instance for this user here.
if systemctl cat "seabird-nc-scan@.timer" &>/dev/null; then
    systemctl enable --now "seabird-nc-scan@${USERNAME}.timer"
    ok "seabird-nc-scan@${USERNAME}.timer enabled"
else
    echo "warning: seabird-nc-scan@.timer template not found" >&2
    echo "         Run install-services.sh first, then re-run this script." >&2
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo
echo "User '${USERNAME}' is ready."
echo "  Linux home:      /home/${USERNAME}/"
echo "  Nextcloud files: ${NC_MOUNT_DIR}/   (bind-mounted)"
echo "  Nextcloud web:   http://seabird.local:8080"
echo
