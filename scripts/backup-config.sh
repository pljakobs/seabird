#!/usr/bin/env bash
# backup-config.sh — back up device-specific configuration to git or SSH/rsync
#
# What is backed up:
#   /etc/seabird/                — service env files, avnav.mac, install-state.json
#   /srv/seabird/avnav/          — routes, tracks, layouts, server config
#                                  (charts and mapproxy tile caches are excluded)
#
# Two transport modes:
#   --git URL      Push a timestamped commit to a git repository.
#                  A persistent working clone is kept at /var/lib/seabird-backup/git/.
#   --ssh DEST     rsync the staged tree to an SSH path.
#                  DEST format: user@host:/path  (e.g. pi@nas.home:/backups/seabird)
#
# Encryption (git mode only):
#   --age-recipient PUBKEY
#                  Encrypt *.env files with an age public key before committing.
#                  The key must be YOUR key from your own machine (age-keygen or
#                  ssh-to-age), NOT a key generated on this device.  The private
#                  key never touches this device; you decrypt on your laptop.
#                  Obtain your public key with:  age-keygen -y ~/.config/age/key.txt
#                  or for SSH keys:              age-keygen -y ~/.ssh/id_ed25519.pub
#
# Other options:
#   --hostname NAME   Override the hostname used in the git commit message
#   --dry-run         Print what would happen without making any changes
#   --install-timer   Install a systemd timer to run this script daily
#   --help            Show this help and exit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_WORK_DIR="/var/lib/seabird-backup/git"
STAGING_DIR="/var/lib/seabird-backup/staging"
SELF="$(realpath "${BASH_SOURCE[0]}")"

MODE=""           # "git" | "ssh"
GIT_REMOTE=""
SSH_DEST=""
AGE_RECIPIENT=""
DRY_RUN=false
INSTALL_TIMER=false
DEVICE_HOST="$(hostname -s 2>/dev/null || echo seabird)"

# ── argument parsing ──────────────────────────────────────────────────────────

usage() {
    sed -n '/^# backup-config/,/^[^#]/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \?//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --git)             MODE=git;   GIT_REMOTE="$2";    shift 2 ;;
        --ssh)             MODE=ssh;   SSH_DEST="$2";      shift 2 ;;
        --age-recipient)   AGE_RECIPIENT="$2";             shift 2 ;;
        --hostname)        DEVICE_HOST="$2";               shift 2 ;;
        --dry-run)         DRY_RUN=true;                   shift   ;;
        --install-timer)   INSTALL_TIMER=true;             shift   ;;
        --help|-h)         usage 0 ;;
        *)  echo "error: unknown option: $1" >&2; usage 1 ;;
    esac
done

if [[ -z "${MODE}" ]]; then
    echo "error: specify either --git URL or --ssh DEST" >&2
    usage 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root" >&2
    exit 1
fi

if [[ -n "${AGE_RECIPIENT}" ]] && ! command -v age &>/dev/null; then
    echo "error: --age-recipient requires the 'age' binary (dnf install age)" >&2
    exit 1
fi

# ── dry-run wrapper ───────────────────────────────────────────────────────────

run() {
    if "${DRY_RUN}"; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

# ── timer installer ───────────────────────────────────────────────────────────

install_timer() {
    local svc_file="/etc/systemd/system/seabird-backup.service"
    local timer_file="/etc/systemd/system/seabird-backup.timer"

    local exec_args=("${SELF}")
    [[ "${MODE}" == "git" ]] && exec_args+=(--git "${GIT_REMOTE}")
    [[ "${MODE}" == "ssh" ]] && exec_args+=(--ssh "${SSH_DEST}")
    [[ -n "${AGE_RECIPIENT}" ]] && exec_args+=(--age-recipient "${AGE_RECIPIENT}")
    exec_args+=(--hostname "${DEVICE_HOST}")

    echo "Installing systemd timer → ${timer_file}"
    if ! "${DRY_RUN}"; then
        cat > "${svc_file}" <<EOF
[Unit]
Description=Seabird device config backup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${exec_args[*]}
EOF

        cat > "${timer_file}" <<EOF
[Unit]
Description=Daily seabird device config backup

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload
        systemctl enable --now seabird-backup.timer
        echo "  timer enabled — next run: $(systemctl show seabird-backup.timer --value -p NextElapseUSecRealtime 2>/dev/null || echo unknown)"
    else
        echo "[dry-run] would write ${svc_file} and ${timer_file}"
        echo "[dry-run] ExecStart: ${exec_args[*]}"
    fi
}

if "${INSTALL_TIMER}"; then
    install_timer
    exit 0
fi

# ── source collector ──────────────────────────────────────────────────────────
# Assembles all backup content into a staging directory. Both transport modes
# read from here so the include/exclude logic lives in one place.

collect_sources() {
    local dest="$1"

    # /etc/seabird/ — env files, avnav.mac, install-state.json
    if [[ -d /etc/seabird ]]; then
        run mkdir -p "${dest}/etc/seabird"
        run rsync -a --delete \
            --exclude='*.example' \
            /etc/seabird/ "${dest}/etc/seabird/"
    fi

    # /srv/seabird/avnav/ — config, routes, tracks, layouts
    # Exclude charts (large, re-downloadable) and mapproxy tile caches and logs
    if [[ -d /srv/seabird/avnav ]]; then
        run mkdir -p "${dest}/srv/seabird/avnav"
        run rsync -a --delete \
            --exclude='charts/' \
            --exclude='mapproxy/cache_data/' \
            --exclude='import/' \
            --exclude='log/' \
            --exclude='*.log' \
            --exclude='*.log.*' \
            /srv/seabird/avnav/ "${dest}/srv/seabird/avnav/"
    fi
}

# ── secret encryptor ──────────────────────────────────────────────────────────
# Encrypts *.env files in the staging tree in-place using the caller's public
# key.  The plaintext is removed after encryption so it never reaches the
# transport layer.  Non-secret files (tracks, routes, config) are left as-is.

encrypt_secrets() {
    local dest="$1"

    echo "  encrypting secrets with age recipient..."
    while IFS= read -r -d '' envfile; do
        if "${DRY_RUN}"; then
            echo "[dry-run] age -r ${AGE_RECIPIENT} -o ${envfile}.age ${envfile} && rm ${envfile}"
        else
            age -r "${AGE_RECIPIENT}" -o "${envfile}.age" "${envfile}"
            rm -f "${envfile}"
        fi
    done < <(find "${dest}" -name '*.env' -print0)
}

# ── git mode ──────────────────────────────────────────────────────────────────

backup_git() {
    local timestamp commit_msg

    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    commit_msg="backup(${DEVICE_HOST}): ${timestamp}"

    echo "=== git backup → ${GIT_REMOTE} ==="

    # Initialise or update the local working clone
    if [[ -d "${GIT_WORK_DIR}/.git" ]]; then
        echo "  pulling ${GIT_WORK_DIR}..."
        run git -C "${GIT_WORK_DIR}" pull --ff-only --quiet
    else
        echo "  cloning ${GIT_REMOTE} → ${GIT_WORK_DIR}..."
        if "${DRY_RUN}"; then
            echo "[dry-run] git clone ${GIT_REMOTE} ${GIT_WORK_DIR}"
        else
            mkdir -p "${GIT_WORK_DIR}"
            # Clone; if the remote is empty the clone fails — handle that case
            if ! git clone --quiet "${GIT_REMOTE}" "${GIT_WORK_DIR}" 2>/dev/null; then
                git -C "${GIT_WORK_DIR}" init --quiet
                git -C "${GIT_WORK_DIR}" remote add origin "${GIT_REMOTE}"
            fi
            git -C "${GIT_WORK_DIR}" config user.name  "seabird-backup"
            git -C "${GIT_WORK_DIR}" config user.email "root@${DEVICE_HOST}"
        fi
    fi

    # Collect sources into a fresh staging area, then sync into the git tree
    echo "  collecting sources..."
    if ! "${DRY_RUN}"; then
        rm -rf "${STAGING_DIR}"
        mkdir -p "${STAGING_DIR}"
    fi
    collect_sources "${STAGING_DIR}"

    [[ -n "${AGE_RECIPIENT}" ]] && encrypt_secrets "${STAGING_DIR}"

    # Write a README once so the repo is never empty
    if [[ ! -f "${GIT_WORK_DIR}/README.md" ]] && ! "${DRY_RUN}"; then
        local enc_note=""
        [[ -n "${AGE_RECIPIENT}" ]] && enc_note="  *.env files are age-encrypted for recipient: ${AGE_RECIPIENT}"
        cat > "${GIT_WORK_DIR}/README.md" <<EOF
# seabird device config backup

Backed up by \`backup-config.sh\` from \`${DEVICE_HOST}\`.
${enc_note}

## Contents

| Path | Contents |
|------|----------|
| \`etc/seabird/avnav.mac\` | Stable avnav container MAC (ochartsng licensing) |
| \`etc/seabird/*.env[.age]\` | Service credentials (grafana, influxdb, nextcloud, pihole) |
| \`etc/seabird/install-state.json\` | Recorded install options |
| \`srv/seabird/avnav/avnav_server.xml\` | AvNav server configuration |
| \`srv/seabird/avnav/routes/\` | Routes and waypoints (GPX) |
| \`srv/seabird/avnav/tracks/\` | GPS tracks (GPX) |
| \`srv/seabird/avnav/layout/\` | AvNav UI layouts |
| \`srv/seabird/avnav/ochartsng/\` | ochartsng plugin settings |
EOF
    fi

    # Mirror staging → git working tree (keep .git intact)
    echo "  syncing staged content → git working tree..."
    run rsync -a --delete \
        --exclude='.git' \
        --exclude='README.md' \
        "${STAGING_DIR}/" "${GIT_WORK_DIR}/"

    # Stage, commit (skip if nothing changed), and push
    if "${DRY_RUN}"; then
        echo "[dry-run] git add -A && git commit && git push"
        return
    fi

    git -C "${GIT_WORK_DIR}" add -A

    if git -C "${GIT_WORK_DIR}" diff --cached --quiet; then
        echo "  no changes since last backup — nothing to commit"
    else
        git -C "${GIT_WORK_DIR}" commit --quiet -m "${commit_msg}"
        git -C "${GIT_WORK_DIR}" push --quiet origin HEAD
        echo "  committed and pushed: ${commit_msg}"
    fi

    chmod 700 "${GIT_WORK_DIR}"
}

# ── ssh/rsync mode ────────────────────────────────────────────────────────────

backup_ssh() {
    echo "=== rsync backup → ${SSH_DEST} ==="

    local dest_host dest_path
    dest_host="${SSH_DEST%%:*}"
    dest_path="${SSH_DEST#*:}"

    # Collect sources locally first
    echo "  collecting sources..."
    if ! "${DRY_RUN}"; then
        rm -rf "${STAGING_DIR}"
        mkdir -p "${STAGING_DIR}"
    fi
    collect_sources "${STAGING_DIR}"

    if ! "${DRY_RUN}"; then
        ssh "${dest_host}" "mkdir -p '${dest_path}'"
    else
        echo "[dry-run] ssh ${dest_host} mkdir -p '${dest_path}'"
    fi

    run rsync \
        --archive \
        --delete \
        "${STAGING_DIR}/" \
        "${SSH_DEST}/"

    echo "  sync complete → ${SSH_DEST}"
}

# ── dispatch ──────────────────────────────────────────────────────────────────

case "${MODE}" in
    git) backup_git ;;
    ssh) backup_ssh ;;
esac

echo "done."
