#!/usr/bin/env bash
# install-headscale.sh — install tailscale/headscale tooling and optionally join a Headscale network
#
# Usage:
#   sudo scripts/install-headscale.sh [--join=yes|no] [--login-server URL] [--auth-key KEY] [--hostname NAME]
#
# Options:
#   --join=yes|no          Join/rejoin Headscale network now. If omitted, auto-skip when already connected;
#                         otherwise prompt in interactive mode.
#   --login-server URL     Headscale control server URL (e.g. https://hs.example.com)
#   --auth-key KEY         Preauth key for this node; implies --join=yes unless explicitly disabled
#   --hostname NAME        Tailscale node hostname (default: current static hostname)

set -euo pipefail

JOIN=""
LOGIN_SERVER=""
AUTH_KEY=""
NODE_HOSTNAME="$(hostnamectl --static 2>/dev/null || hostname)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --join=yes) JOIN=yes; shift ;;
        --join=no)  JOIN=no;  shift ;;
        --join)
            if [[ "${2:-}" == "yes" || "${2:-}" == "no" ]]; then
                JOIN="$2"; shift 2
            else
                echo "error: --join requires 'yes' or 'no'" >&2; exit 1
            fi ;;
        --login-server) LOGIN_SERVER="${2:-}"; shift 2 ;;
        --auth-key) AUTH_KEY="${2:-}"; shift 2 ;;
        --hostname) NODE_HOSTNAME="${2:-}"; shift 2 ;;
        -h|--help)
            sed -n '/^# install-headscale/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) echo "error: unknown option '$1'" >&2; exit 1 ;;
    esac
done

# Supplying an auth key should be enough for non-interactive automatic join.
if [[ -n "${AUTH_KEY}" && -z "${JOIN}" ]]; then
    JOIN=yes
fi

if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root" >&2
    exit 1
fi

echo "Installing Tailscale client..."
if ! rpm -q tailscale &>/dev/null; then
    dnf install -y tailscale
fi

echo "Trying to install headscale CLI (optional on the box)..."
if ! rpm -q headscale &>/dev/null; then
    if dnf install -y headscale; then
        echo "  headscale installed"
    else
        echo "  WARNING: headscale package not available in configured repos; continuing with tailscale only"
    fi
fi

echo "Enabling tailscaled..."
systemctl enable --now tailscaled

# Detect current connectivity once; used for skip/prompt behavior below.
if tailscale status --self &>/dev/null; then
    CURRENT_JOINED=yes
else
    CURRENT_JOINED=no
fi

# If already connected and no explicit join/rejoin requested, skip this step.
if [[ -z "${JOIN}" && "${CURRENT_JOINED}" == yes ]]; then
    echo "Tailscale is already connected — skipping Headscale join step."
    JOIN=no
fi

if [[ -z "${JOIN}" ]]; then
    if [[ -t 0 ]]; then
        echo "Tailscale is currently: NOT CONNECTED"
        read -r -p "Change this setting? Join/rejoin Headscale now? [y/N]: " _JOIN_CHANGE
        if [[ "${_JOIN_CHANGE}" =~ ^[Yy]$ ]]; then
            JOIN=yes
        else
            JOIN=no
        fi
    else
        JOIN=no
    fi
fi

if [[ "${JOIN}" == "yes" ]]; then
    if [[ -z "${LOGIN_SERVER}" && -t 0 ]]; then
        read -r -p "Headscale login server URL (e.g. https://hs.example.com): " LOGIN_SERVER
    fi
    if [[ -z "${AUTH_KEY}" && -t 0 ]]; then
        read -r -p "Headscale preauth key: " AUTH_KEY
    fi

    if [[ -z "${LOGIN_SERVER}" || -z "${AUTH_KEY}" ]]; then
        echo "error: joining requires --login-server and --auth-key (or interactive input)" >&2
        exit 1
    fi

    echo "Joining Headscale network..."
    tailscale up \
        --login-server="${LOGIN_SERVER}" \
        --authkey="${AUTH_KEY}" \
        --hostname="${NODE_HOSTNAME}" \
        --accept-routes=true \
        --accept-dns=true

    echo "Joined. Current Tailscale identity:"
    tailscale status --self || true
else
    echo "Headscale join step skipped."
    echo "Join later with:"
    echo "  tailscale up --login-server=<URL> --authkey=<KEY> --hostname=${NODE_HOSTNAME} --accept-routes=true --accept-dns=true"
fi
