#!/usr/bin/env bash

set -euo pipefail

applied=false

for dev in /sys/bus/pci/devices/*; do
    [[ -f "${dev}/vendor" && -f "${dev}/device" && -w "${dev}/power/control" ]] || continue

    if [[ "$(<"${dev}/vendor")" == "0x03f0" && "$(<"${dev}/device")" == "0x0a6c" ]]; then
        echo on > "${dev}/power/control"
        applied=true
    fi
done

if [[ "${applied}" != true ]]; then
    echo "no matching 03f0:0a6c modem with writable power/control found" >&2
fi
