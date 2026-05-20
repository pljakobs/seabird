#!/usr/bin/env bash
# install-firewall.sh — configure firewalld for the seabird boat router
#
# Zones:
#   wan  — wwan0, wlan0, end0   (uplink, DROP inbound, masquerade)
#   lan  — wlp6s0, enp4s0       (crew network, ACCEPT)
#
# Policy:
#   lan-to-wan  — allow crew clients to reach all WAN uplinks
#
# Run as root. Safe to re-run (all operations are idempotent).
#
# Options:
#   --allow-wan-ssh=yes   Open port 22 on the WAN zone, install fail2ban,
#                         and disable SSH password authentication.
#   --allow-wan-ssh=no    (default) SSH is only reachable from the LAN zone.
#   --mode=prod           (default) end0 is WAN — fully firewalled upstream.
#   --mode=dev            end0 joins the lan zone — all services reachable
#                         from the upstream interface (for development/testing).
#
# Multi-WAN routing note:
#   Firewalld handles the firewall and NAT. For opportunistic multi-WAN
#   (ECMP routes + per-flow return routing) you also need per-interface
#   routing tables and ip rules — see scripts/install-routing.sh.

set -euo pipefail

WAN_INTERFACES=(wwan0 wlan0 end0)
LAN_INTERFACES=(wlp6s0 enp4s0)
ALLOW_WAN_SSH=""   # empty = not yet decided
MODE=""            # empty = not yet decided

# ── argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --allow-wan-ssh=yes) ALLOW_WAN_SSH=yes; shift ;;
        --allow-wan-ssh=no)  ALLOW_WAN_SSH=no;  shift ;;
        --allow-wan-ssh)
            if [[ "${2:-}" == "yes" || "${2:-}" == "no" ]]; then
                ALLOW_WAN_SSH="$2"; shift 2
            else
                echo "error: --allow-wan-ssh requires 'yes' or 'no'" >&2; exit 1
            fi ;;
        --mode=prod) MODE=prod; shift ;;
        --mode=dev)  MODE=dev;  shift ;;
        --mode)
            if [[ "${2:-}" == "prod" || "${2:-}" == "dev" ]]; then
                MODE="$2"; shift 2
            else
                echo "error: --mode requires 'prod' or 'dev'" >&2; exit 1
            fi ;;
        -h|--help)
            sed -n '/^# install-firewall/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) echo "error: unknown option '$1'" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZONE_SRC="${SCRIPT_DIR}/../config/firewalld/zones"
DISPATCHER_SRC="${SCRIPT_DIR}/../config/nm-dispatcher"

# ── prerequisites ─────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root" >&2
    exit 1
fi

# ── prompt for firewall mode if not specified and stdin is a terminal ───────

if [[ -z "${MODE}" ]]; then
    _END0_ZONE=$(firewall-cmd --get-zone-of-interface=end0 2>/dev/null || true)
    if [[ "${_END0_ZONE}" == "lan" ]]; then
        _CURRENT_MODE=dev
    else
        _CURRENT_MODE=prod
    fi

    if [[ -t 0 ]]; then
        if [[ "${_CURRENT_MODE}" == "dev" ]]; then
            echo "Firewall mode is currently: DEVELOPMENT"
            echo "  end0 is in LAN (services reachable from upstream interface)."
        else
            echo "Firewall mode is currently: PRODUCTION"
            echo "  end0 is in WAN (upstream side firewalled)."
        fi
        read -r -p "Change this setting? [y/N]: " _MODE_CHANGE
        if [[ "${_MODE_CHANGE}" =~ ^[Yy]$ ]]; then
            if [[ "${_CURRENT_MODE}" == "dev" ]]; then
                MODE=prod
            else
                MODE=dev
            fi
        else
            MODE="${_CURRENT_MODE}"
        fi
    else
        # Non-interactive (called by automation) defaults to production mode.
        MODE=prod
    fi
fi

# ── prompt for WAN SSH if not specified and stdin is a terminal ───────────────

if [[ -z "${ALLOW_WAN_SSH}" ]]; then
    if [[ -t 0 ]]; then
        # Detect current state: is ssh present in the wan zone?
        if firewall-cmd --zone=wan --query-service=ssh &>/dev/null 2>&1; then
            _WAN_SSH_CURRENT=yes
        else
            _WAN_SSH_CURRENT=no
        fi

        if [[ "${_WAN_SSH_CURRENT}" == yes ]]; then
            echo "SSH on WAN interfaces is currently: ENABLED"
        else
            echo "SSH on WAN interfaces is currently: DISABLED"
        fi
        echo "  Enabling opens port 22 to the internet, installs fail2ban,"
        echo "  and disables password authentication (key-only login)."
        read -r -p "Change this setting? [y/N]: " _WAN_SSH_CHANGE
        if [[ "${_WAN_SSH_CHANGE}" =~ ^[Yy]$ ]]; then
            if [[ "${_WAN_SSH_CURRENT}" == yes ]]; then
                ALLOW_WAN_SSH=no
            else
                ALLOW_WAN_SSH=yes
            fi
        else
            ALLOW_WAN_SSH="${_WAN_SSH_CURRENT}"
        fi
    else
        # Non-interactive (called from install-all.sh without flag) — preserve current state
        if firewall-cmd --zone=wan --query-service=ssh &>/dev/null 2>&1; then
            ALLOW_WAN_SSH=yes
        else
            ALLOW_WAN_SSH=no
        fi
    fi
fi

if ! systemctl is-active --quiet firewalld; then
    echo "Starting firewalld..."
    systemctl enable --now firewalld
fi

# ── install zone definitions ──────────────────────────────────────────────────

echo "Installing zone definitions..."
install -m 0644 "${ZONE_SRC}/wan.xml"     /etc/firewalld/zones/wan.xml
install -m 0644 "${ZONE_SRC}/lan.xml"     /etc/firewalld/zones/lan.xml
install -m 0644 "${ZONE_SRC}/headnet.xml" /etc/firewalld/zones/headnet.xml

firewall-cmd --reload

# ── WAN zone: assign interfaces ───────────────────────────────────────────────
# In dev mode, end0 moves to lan so all services are reachable from the
# upstream interface. In prod mode (default) end0 stays on wan.

if [[ "${MODE}" == "dev" ]]; then
    _EFFECTIVE_WAN=(wwan0 wlan0)
    _EFFECTIVE_LAN=(wlp6s0 enp4s0 end0)
    echo "Mode: dev — end0 placed in lan zone (services reachable from upstream)"
else
    _EFFECTIVE_WAN=("${WAN_INTERFACES[@]}")
    _EFFECTIVE_LAN=("${LAN_INTERFACES[@]}")
    echo "Mode: prod — end0 in wan zone (firewalled upstream)"
fi


# Helper: assign iface to zone in both firewalld (permanent) AND the NM
# connection profile. Without the NM step, NetworkManager overrides the
# firewalld permanent zone whenever it brings the interface up, leaving it
# in the system-default FedoraServer zone at runtime.
_assign_zone() {
    local iface="$1" zone="$2"
    local current_zone
    current_zone=$(firewall-cmd --get-zone-of-interface="${iface}" 2>/dev/null || true)
    if [[ -n "${current_zone}" && "${current_zone}" != "${zone}" ]]; then
        firewall-cmd --permanent --zone="${current_zone}" --remove-interface="${iface}" || true
    fi
    firewall-cmd --permanent --zone="${zone}" --add-interface="${iface}"

    # Sync the NM connection profile so the zone survives reconnects/reboots.
    # We try active profile first, then inactive profiles with matching
    # interface-name. For cellular links, firewalld often sees "wwan0" while
    # NM activates a "wwan*mbim*" device, so fall back to GSM profiles.
    local nm_con
    nm_con=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | awk -F: -v dev="${iface}" '$2==dev{print $1; exit}')
    if [[ -z "${nm_con}" ]]; then
        # Some NM versions do not support connection.interface-name in this view;
        # NAME,DEVICE is widely supported and reports '--' for inactive profiles.
        nm_con=$(nmcli -t -f NAME,DEVICE con show 2>/dev/null | awk -F: -v dev="${iface}" '$2==dev{print $1; exit}')
    fi
    if [[ -z "${nm_con}" && "${iface}" =~ ^wwan[0-9]+$ ]]; then
        nm_con=$(nmcli -t -f NAME,TYPE con show 2>/dev/null | awk -F: '$2=="gsm"{print $1; exit}')
    fi
    if [[ -n "${nm_con}" ]]; then
        local route_metric=""
        local metric_note=""
        local modify_args=(connection.zone "${zone}")

        case "${iface}" in
            end0)  route_metric=100 ;;
            wlan0) route_metric=200 ;;
            wwan0) route_metric=50000 ;;
        esac

        if [[ -n "${route_metric}" ]]; then
            modify_args+=(ipv4.route-metric "${route_metric}" ipv6.route-metric "${route_metric}")
            metric_note=", route metric ${route_metric}"
        fi

        nmcli con modify "${nm_con}" "${modify_args[@]}" 2>/dev/null && \
            echo "  ${iface} -> ${zone}${metric_note} (firewalld + NM connection '${nm_con}')" || \
            echo "  ${iface} -> ${zone} (firewalld; NM modify failed — manual updates to '${nm_con}' may be needed)"
    else
        echo "  ${iface} -> ${zone} (firewalld; no active NM connection found for interface)"
    fi
}

echo "Configuring WAN zone..."
for iface in "${_EFFECTIVE_WAN[@]}"; do
    _assign_zone "${iface}" wan
done

# ── LAN zone: assign interfaces ───────────────────────────────────────────────

echo "Configuring LAN zone..."
for iface in "${_EFFECTIVE_LAN[@]}"; do
    _assign_zone "${iface}" lan
done

# ── Headnet zone: assign tailscale0 ──────────────────────────────────────────
# tailscale0 is not managed by NetworkManager, so only firewall-cmd is needed.
# The interface may not exist yet if tailscale hasn't run; --permanent is enough
# — firewalld will apply the assignment when tailscale0 appears.
echo "Configuring headnet zone (tailscale0)..."
if firewall-cmd --permanent --zone=headnet --add-interface=tailscale0 2>/dev/null; then
    echo "  tailscale0 -> headnet"
else
    echo "  tailscale0 -> headnet (already assigned or interface not yet present — will apply on next firewalld reload after tailscale starts)"
fi

# ── forwarding policy: lan → wan ──────────────────────────────────────────────
# Requires firewalld >= 0.9.0 (Fedora 34+). Allows LAN clients to reach WAN.

echo "Configuring forwarding policy (lan -> wan)..."
if firewall-cmd --permanent --new-policy=lan-to-wan 2>/dev/null; then
    firewall-cmd --permanent --policy=lan-to-wan --add-ingress-zone=lan
    firewall-cmd --permanent --policy=lan-to-wan --add-egress-zone=wan
    firewall-cmd --permanent --policy=lan-to-wan --set-target=ACCEPT
else
    # Policy already exists — ensure it's configured correctly
    firewall-cmd --permanent --policy=lan-to-wan --add-ingress-zone=lan  2>/dev/null || true
    firewall-cmd --permanent --policy=lan-to-wan --add-egress-zone=wan   2>/dev/null || true
    firewall-cmd --permanent --policy=lan-to-wan --set-target=ACCEPT     2>/dev/null || true
fi

# ── production hardening: block WAN -> Podman published ports ───────────────
# Rootful Podman installs DNAT/forward rules for published ports. In prod mode
# we explicitly drop forwarding from WAN interfaces to the Podman bridge so
# container ports are not reachable from upstream links.
_podman_block_rule_exists() {
    local family="$1"
    local iface="$2"
    local bridge="$3"
    firewall-cmd --permanent --direct --query-rule "${family}" filter FORWARD 0 -i "${iface}" -o "${bridge}" -j DROP &>/dev/null
}

_podman_block_rule_add() {
    local family="$1"
    local iface="$2"
    local bridge="$3"
    if ! _podman_block_rule_exists "${family}" "${iface}" "${bridge}"; then
        firewall-cmd --permanent --direct --add-rule "${family}" filter FORWARD 0 -i "${iface}" -o "${bridge}" -j DROP
    fi
}

_podman_block_rule_remove() {
    local family="$1"
    local iface="$2"
    local bridge="$3"
    if _podman_block_rule_exists "${family}" "${iface}" "${bridge}"; then
        firewall-cmd --permanent --direct --remove-rule "${family}" filter FORWARD 0 -i "${iface}" -o "${bridge}" -j DROP
    fi
}

echo "Configuring WAN access to Podman published ports..."
for iface in "${WAN_INTERFACES[@]}"; do
    if [[ "${MODE}" == "prod" ]]; then
        _podman_block_rule_add ipv4 "${iface}" podman0
        _podman_block_rule_add ipv6 "${iface}" podman0
        echo "  ${iface} -> podman0 blocked (prod)"
    else
        _podman_block_rule_remove ipv4 "${iface}" podman0
        _podman_block_rule_remove ipv6 "${iface}" podman0
        echo "  ${iface} -> podman0 allowed (dev)"
    fi
done

# ── enable IPv4/IPv6 forwarding ───────────────────────────────────────────────

echo "Enabling IP forwarding..."
cat > /etc/sysctl.d/90-seabird-forward.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/90-seabird-forward.conf

# ── apply ─────────────────────────────────────────────────────────────────────

echo "Reloading firewalld..."
firewall-cmd --reload

# ── captive portal dispatcher ─────────────────────────────────────────────────

echo "Installing captive portal dispatcher..."
install -m 0755 "${DISPATCHER_SRC}/90-seabird-captive-portal" \
    /etc/NetworkManager/dispatcher.d/90-seabird-captive-portal

echo "Installing auto-update dispatcher..."
install -m 0755 "${DISPATCHER_SRC}/91-seabird-auto-update" \
    /etc/NetworkManager/dispatcher.d/91-seabird-auto-update

echo "Installing policy routing dispatcher..."
install -m 0755 "${DISPATCHER_SRC}/92-seabird-policy-routing" \
    /etc/NetworkManager/dispatcher.d/92-seabird-policy-routing

# ── caddy config (Caddy runs as a Podman quadlet — see config/quadlets/caddy.container)

echo "Installing Caddy config..."
mkdir -p /etc/caddy/conf.d
install -m 0644 "${SCRIPT_DIR}/../config/caddy/Caddyfile" /etc/caddy/Caddyfile
# AvNav ocharts backend is proxied through Caddy on :8083.
# Direct container-published :8083 has source-dependent hangs on tailnet clients.
# Caddy keeps browser requests to :8083 working while forwarding locally.
# /run/seabird must exist for the portal status JSON
mkdir -p /run/seabird

# Ensure NM connectivity checking is enabled (required to detect portals)
NM_CONF=/etc/NetworkManager/conf.d/90-seabird-connectivity.conf
if [[ ! -f "${NM_CONF}" ]]; then
    cat > "${NM_CONF}" <<'EOF'
[connectivity]
uri=http://fedoraproject.org/static/hotspot.txt
response=OK
interval=60
EOF
    nmcli general reload conf
fi

# ── WAN SSH access ───────────────────────────────────────────────────────────

if [[ "${ALLOW_WAN_SSH}" == "yes" ]]; then
    echo "Enabling SSH on WAN zone..."
    firewall-cmd --permanent --zone=wan --add-service=ssh
    firewall-cmd --reload
    echo "  SSH open on WAN zone"

    # ── disable password authentication in sshd ───────────────────────────────
    echo "Hardening sshd: disabling password authentication..."
    SSHD_DROP_IN=/etc/ssh/sshd_config.d/90-seabird-no-password.conf
    cat > "${SSHD_DROP_IN}" <<'EOF'
# managed by install-firewall.sh — do not edit manually
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
    chmod 0600 "${SSHD_DROP_IN}"
    systemctl reload sshd
    echo "  Password auth disabled, root login restricted to key only"

    # ── install and configure fail2ban ────────────────────────────────────────
    echo "Installing fail2ban..."
    if ! rpm -q fail2ban-server &>/dev/null; then
        dnf install -y fail2ban-server fail2ban-firewalld
    fi

    mkdir -p /etc/fail2ban/jail.d
    cat > /etc/fail2ban/jail.d/90-seabird-sshd.conf <<'EOF'
# managed by install-firewall.sh — do not edit manually
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
bantime.increment = true
EOF

    # Use firewalld backend so bans integrate with the existing zone config
    mkdir -p /etc/fail2ban
    cat > /etc/fail2ban/jail.local <<'EOF'
# managed by install-firewall.sh — do not edit manually
[DEFAULT]
banaction          = firewallcmd-rich-rules[actiontype=<multiport>]
banaction_allports = firewallcmd-allports
EOF

    systemctl enable --now fail2ban
    echo "  fail2ban enabled (sshd jail: 5 attempts / 10 min → 1 h ban, incremental)"
else
    echo "WAN SSH: disabled (--allow-wan-ssh=no)"
    # Remove SSH from WAN zone if it was previously added
    if firewall-cmd --permanent --zone=wan --query-service=ssh 2>/dev/null; then
        firewall-cmd --permanent --zone=wan --remove-service=ssh
        firewall-cmd --reload
        echo "  Removed SSH from WAN zone"
    fi
    # Disable fail2ban if it was previously installed
    if systemctl is-enabled fail2ban &>/dev/null; then
        systemctl disable --now fail2ban
        echo "  fail2ban disabled"
    fi
fi

echo ""
echo "Firewall configuration complete. Active zones:"
firewall-cmd --get-active-zones
echo ""
echo "Policies:"
firewall-cmd --get-policies
