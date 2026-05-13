#!/usr/bin/env bash
# Modem diagnostic script for HP 03f0:0a6c Qualcomm cellular modem
# Usage: ./modem-status.sh [--bring-up]

set -euo pipefail

echo "=== Modem PCI Device Status ==="
lspci -vv -s 05:00.0 || echo "ERROR: Modem device not detected on PCIe bus"

echo ""
echo "=== Kernel Driver Status ==="
if lsmod | grep -q mhi_pci_generic; then
    echo "✓ mhi_pci_generic loaded"
else
    echo "⚠ mhi_pci_generic not loaded, loading..."
    modprobe mhi_pci_generic || echo "ERROR: Failed to load mhi_pci_generic"
fi

echo ""
echo "=== MHI Device Status ==="
ls -la /sys/bus/mhi/devices/ 2>/dev/null || echo "⚠ No MHI devices enumerated yet"

echo ""
echo "=== QMI/MBIM Ports ==="
find /dev -name "*qmi*" -o -name "*mbim*" 2>/dev/null || echo "⚠ No QMI/MBIM ports exposed yet"

echo ""
echo "=== ModemManager Status ==="
systemctl is-active ModemManager || echo "⚠ ModemManager not running"
mmcli -L 2>/dev/null | head -20 || echo "⚠ mmcli command failed"

echo ""
echo "=== Raw Device Info ==="
cat /proc/bus/pci/devices | grep "05:00"

if [[ "${1:-}" == "--bring-up" ]]; then
    echo ""
    echo "=== Attempting Modem Bring-Up ==="
    
    # Ensure ModemManager is running
    systemctl start ModemManager
    sleep 2
    
    # List modems
    echo "Detected modems:"
    mmcli -L
    
    # Get first modem if available
    MODEM=$(mmcli -L 2>/dev/null | grep -oP '/org/freedesktop/ModemManager1/Modem/\K\d+' | head -1)
    
    if [[ -n "$MODEM" ]]; then
        echo ""
        echo "Querying Modem $MODEM:"
        mmcli -m "$MODEM" --simple-connect=pin=0000 2>/dev/null || \
        mmcli -m "$MODEM" || echo "ERROR: Failed to query modem"
    else
        echo "ERROR: No modems detected by ModemManager"
        echo "Trying raw QMI probe..."
        qmi-cli --service=dms --operation=get-device-info 2>/dev/null || true
    fi
fi
