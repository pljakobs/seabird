# Cellular Modem Setup on Raspberry Pi CM4

## Hardware

- **Raspberry Pi CM4** (BCM2711, aarch64)
- **Modem**: Foxconn T99W175 (Qualcomm SDX55, 5G) — PCI ID `03f0:0a6c`
  - Alternatively tested: Quectel EM120R-GL (Qualcomm SDX24, LTE) — PCI ID `17cb:0304`
- Connected via **ASMedia ASM1184e** PCIe switch at slot `05:00.0`

## The Problem

Both modems fail MHI probe with `error -12` (ENOMEM) out of the box on CM4:

```
mhi-pci-generic 0000:05:00.0: failed to prepare MHI controller
mhi-pci-generic 0000:05:00.0: probe with driver mhi-pci-generic failed with error -12
```

**Root cause:** The BCM2711 PCIe controller's only inbound DMA window is mapped at PCIe
address `0x400000000` by default. Both modems have a 32-bit DMA mask (max addressable:
`0xFFFFFFFF`). The modem cannot reach any RAM through PCIe, so every `dma_alloc_coherent()`
call returns NULL — reported as ENOMEM by the MHI driver.

Visible in dmesg:
```
brcm-pcie fd500000.pcie:   IB MEM 0x0000000000..0x01ffffffff -> 0x0400000000
```

## The Fix

Add the `pcie-32bit-dma` device tree overlay. This adds a second inbound PCIe window
at address `0x0`, mapping 2GB of RAM directly to PCIe address space where 32-bit DMA
devices can reach it.

```bash
echo "dtoverlay=pcie-32bit-dma" | sudo tee -a /boot/efi/config.txt
sudo reboot
```

After reboot, dmesg should show:
```
brcm-pcie fd500000.pcie:   IB MEM 0x0000000000..0x007fffffff -> 0x0000000000
```

The overlay file is at `/boot/efi/overlays/pcie-32bit-dma.dtbo` and ships with the
standard Raspberry Pi firmware.

## Kernel Drivers Required

The following kernel modules must be loaded (present in Fedora 44 kernel):

```
mhi
mhi_pci_generic
mhi_net
```

They load automatically on device detection. No manual `modprobe` needed.

## Firmware

The T99W175 requires a firehose loader at boot:

```
/lib/firmware/qcom/sdx55m/foxconn/prog_firehose_sdx55.mbn
```

This file is **not** in the standard `linux-firmware` package. Obtain it from the
[T99W175_Recovery](https://github.com/abcdtkd333/T99W175_Recovery) repository or
extract it from a host that has previously paired with the modem.

The EM120R-GL (SDX24) does not require additional firmware beyond what ships in
`linux-firmware`.

## Verification

After reboot with the overlay active:

```bash
# Modem should appear in ModemManager
mmcli -L

# Full modem status
mmcli -m 0

# Enable the modem
mmcli -m 0 -e

# Connect (adjust APN for your carrier)
mmcli -m 0 --simple-connect="apn=web.vodafone.de"

# Check network interface
ip addr show wwan0
```

## Kernel Command Line

The following parameters tuned during investigation are **not required** once the
overlay is in place and can be removed:

```
mem=3G cma=256M coherent_pool=16M swiotlb=32768 pcie_aspm=off iommu.passthrough=1
```

Remove them with:
```bash
sudo grubby --update-kernel=DEFAULT --remove-args="mem=3G cma=256M coherent_pool=16M swiotlb=32768 pcie_aspm=off iommu.passthrough=1"
```

## Notes

- The `pcie-32bit-dma` overlay is a well-known RPi fix for 32-bit DMA devices (USB
  controllers, some NICs). It is documented in `/boot/efi/overlays/README`.
- The fix is platform-level and applies to any 32-bit DMA device behind the BCM2711
  PCIe controller, not just modems.
- A cold power cycle (full power-off, not just reboot) is sometimes needed if the modem
  has entered a stuck reset state after repeated failed probes.
