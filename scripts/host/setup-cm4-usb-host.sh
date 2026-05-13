#!/usr/bin/env bash
set -euo pipefail

# Host-side setup for CM4 USB mass-storage access (rpiboot workflow).
# This script installs only host prerequisites; it does not modify the CM4 image.

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

if [[ -f /etc/fedora-release ]]; then
  dnf -y install \
    git \
    make \
    gcc \
    libusb1-devel \
    usbutils \
    util-linux \
    udisks2
elif [[ -f /etc/debian_version ]]; then
  apt-get update
  apt-get install -y \
    git \
    make \
    gcc \
    libusb-1.0-0-dev \
    usbutils \
    util-linux \
    udisks2
else
  echo "Unsupported host distro. Install manually: git make gcc libusb-dev usbutils util-linux udisks2" >&2
  exit 2
fi

WORKDIR="${WORKDIR:-/opt/rpiboot}"

if [[ ! -d "${WORKDIR}" ]]; then
  git clone --depth=1 https://github.com/raspberrypi/usbboot.git "${WORKDIR}"
fi

make -C "${WORKDIR}"
install -m 0755 "${WORKDIR}/rpiboot" /usr/local/bin/rpiboot

cat >/etc/udev/rules.d/99-cm4-rpiboot.rules <<'EOF'
SUBSYSTEM=="usb", ATTR{idVendor}=="0a5c", ATTR{idProduct}=="2711", MODE="0660", GROUP="plugdev"
EOF

udevadm control --reload-rules
udevadm trigger

echo "Host setup complete. Next: run scripts/host/check-cm4-usb-host.sh"
