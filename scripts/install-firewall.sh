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
#
# Multi-WAN routing note:
#   Firewalld handles the firewall and NAT. For opportunistic multi-WAN
#   (ECMP routes + per-flow return routing) you also need per-interface
#   routing tables and ip rules — see scripts/install-routing.sh.

set -euo pipefail

WAN_INTERFACES=(wwan0 wlan0 end0)
LAN_INTERFACES=(wlp6s0 enp4s0)
ALLOW_WAN_SSH=no

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

if ! systemctl is-active --quiet firewalld; then
    echo "Starting firewalld..."
    systemctl enable --now firewalld
fi

# ── install zone definitions ──────────────────────────────────────────────────

echo "Installing zone definitions..."
install -m 0644 "${ZONE_SRC}/wan.xml" /etc/firewalld/zones/wan.xml
install -m 0644 "${ZONE_SRC}/lan.xml" /etc/firewalld/zones/lan.xml

firewall-cmd --reload

# ── WAN zone: assign interfaces ───────────────────────────────────────────────

echo "Configuring WAN zone..."
for iface in "${WAN_INTERFACES[@]}"; do
    # Remove from whatever zone it may already be in
    current_zone=$(firewall-cmd --get-zone-of-interface="${iface}" 2>/dev/null || true)
    if [[ -n "${current_zone}" && "${current_zone}" != "wan" ]]; then
        firewall-cmd --permanent --zone="${current_zone}" --remove-interface="${iface}" || true
    fi
    firewall-cmd --permanent --zone=wan --add-interface="${iface}"
    echo "  ${iface} -> wan"
done

# ── LAN zone: assign interfaces ───────────────────────────────────────────────

echo "Configuring LAN zone..."
for iface in "${LAN_INTERFACES[@]}"; do
    current_zone=$(firewall-cmd --get-zone-of-interface="${iface}" 2>/dev/null || true)
    if [[ -n "${current_zone}" && "${current_zone}" != "lan" ]]; then
        firewall-cmd --permanent --zone="${current_zone}" --remove-interface="${iface}" || true
    fi
    firewall-cmd --permanent --zone=lan --add-interface="${iface}"
    echo "  ${iface} -> lan"
done

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

# ── caddy config (Caddy runs as a Podman quadlet — see config/quadlets/caddy.container)

echo "Installing Caddy config..."
mkdir -p /etc/caddy/conf.d
install -m 0644 "${SCRIPT_DIR}/../config/caddy/Caddyfile" /etc/caddy/Caddyfile
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
