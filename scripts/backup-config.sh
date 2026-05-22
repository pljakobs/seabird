#!/usr/bin/env bash
# backup-config.sh — back up device-specific configuration from /etc/seabird/
#
# Two transport modes:
#   --git URL      Push a timestamped commit to a private git repository.
#                  A persistent working clone is kept at /var/lib/seabird-backup/git/.
#   --ssh DEST     rsync the config directory to an SSH path.
#                  DEST format: user@host:/path  (e.g. pi@nas.home:/backups/seabird)
#
# Other options:
#   --hostname NAME   Override the hostname used in the git commit message
#   --dry-run         Print what would happen without making any changes
#   --help            Show this help and exit
#
# WARNING: /etc/seabird/ contains service secrets (passwords, tokens).
#          Use a PRIVATE repository or a secured SSH destination.
#
# The script can be installed as a daily systemd timer by running:
#   backup-config.sh --install-timer --git URL [--hostname NAME]
#   backup-config.sh --install-timer --ssh DEST [--hostname NAME]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="/etc/seabird"
GIT_WORK_DIR="/var/lib/seabird-backup/git"
SELF="$(realpath "${BASH_SOURCE[0]}")"

MODE=""           # "git" | "ssh"
GIT_REMOTE=""
SSH_DEST=""
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
        --git)           MODE=git;   GIT_REMOTE="$2"; shift 2 ;;
        --ssh)           MODE=ssh;   SSH_DEST="$2";   shift 2 ;;
        --hostname)      DEVICE_HOST="$2"; shift 2 ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --install-timer) INSTALL_TIMER=true; shift ;;
        --help|-h)       usage 0 ;;
        *)  echo "error: unknown option: $1" >&2; usage 1 ;;
    esac
done

if [[ -z "${MODE}" ]]; then
    echo "error: specify either --git URL or --ssh DEST" >&2
    usage 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root (reads /etc/seabird/ secrets)" >&2
    exit 1
fi

if [[ ! -d "${SOURCE_DIR}" ]]; then
    echo "error: ${SOURCE_DIR} does not exist — nothing to back up" >&2
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
        run mkdir -p "${GIT_WORK_DIR}"
        if "${DRY_RUN}"; then
            echo "[dry-run] git clone ${GIT_REMOTE} ${GIT_WORK_DIR}"
        else
            # Clone; if the remote is empty the clone fails — handle that case
            if ! git clone --quiet "${GIT_REMOTE}" "${GIT_WORK_DIR}" 2>/dev/null; then
                git -C "${GIT_WORK_DIR}" init --quiet
                git -C "${GIT_WORK_DIR}" remote add origin "${GIT_REMOTE}"
            fi
            # Ensure git identity is set (non-interactive environment)
            git -C "${GIT_WORK_DIR}" config user.name  "seabird-backup"
            git -C "${GIT_WORK_DIR}" config user.email "root@${DEVICE_HOST}"
        fi
    fi

    # Write a README once so the repo is never empty
    if [[ ! -f "${GIT_WORK_DIR}/README.md" ]] && ! "${DRY_RUN}"; then
        cat > "${GIT_WORK_DIR}/README.md" <<'EOF'
# seabird device config backup

This repository holds per-device configuration backed up from `/etc/seabird/`
by `backup-config.sh`.

**WARNING:** This repository contains service secrets. Keep it private.

| File | Contents |
|------|----------|
| `avnav.mac` | Stable avnav container MAC (required for ochartsng licensing) |
| `grafana.env` | Grafana admin credentials |
| `influxdb.env` | InfluxDB token and passwords |
| `nextcloud.env` | Nextcloud database password |
| `pihole.env` | Pi-hole web password |
| `install-state.json` | Recorded install options |
EOF
    fi

    # Sync source → working directory (keep only files present in source)
    echo "  syncing ${SOURCE_DIR}/ → ${GIT_WORK_DIR}/..."
    run rsync -a --delete \
        --exclude='.git' \
        --exclude='*.example' \
        "${SOURCE_DIR}/" "${GIT_WORK_DIR}/"

    # Stage, commit (skip if nothing changed), and push
    if "${DRY_RUN}"; then
        echo "[dry-run] git -C ${GIT_WORK_DIR} add -A"
        echo "[dry-run] git -C ${GIT_WORK_DIR} commit -m '${commit_msg}'"
        echo "[dry-run] git -C ${GIT_WORK_DIR} push origin HEAD"
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

    # Lock down the working directory — it contains secrets
    chmod 700 "${GIT_WORK_DIR}"
}

# ── ssh/rsync mode ────────────────────────────────────────────────────────────

backup_ssh() {
    echo "=== rsync backup → ${SSH_DEST} ==="

    # Ensure the destination directory exists
    local dest_host dest_path
    dest_host="${SSH_DEST%%:*}"
    dest_path="${SSH_DEST#*:}"

    if ! "${DRY_RUN}"; then
        ssh "${dest_host}" "mkdir -p '${dest_path}'"
    else
        echo "[dry-run] ssh ${dest_host} mkdir -p '${dest_path}'"
    fi

    run rsync \
        --archive \
        --delete \
        --exclude='*.example' \
        --rsync-path="rsync" \
        "${SOURCE_DIR}/" \
        "${SSH_DEST}/"

    echo "  sync complete → ${SSH_DEST}"
}

# ── dispatch ──────────────────────────────────────────────────────────────────

case "${MODE}" in
    git) backup_git ;;
    ssh) backup_ssh ;;
esac

echo "done."
