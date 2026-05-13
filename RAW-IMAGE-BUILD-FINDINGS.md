# Raw Image Build Findings (bootc / bootc-image-builder)

Date: 2026-05-12
Repo: boat-router
Host: Fedora 43 x86_64 (`7.0.4-100.fc43.x86_64`)
Goal: Build arm64 raw image from x86_64 host using bootc-image-builder, preferably with `--in-vm`.

## Executive Summary

We validated that image build, package sets, cross-arch container execution, and registry access are all working.
The remaining failures are in the osbuild raw-image stage:

1. VM mode (`BIB_IN_VM=true`) fails during QEMU VM startup:
   - `qemu: linux kernel too old to load a ram disk`
   - `RuntimeError: QEMU did not become ready`

2. Host mode (`BIB_IN_VM=false`) advances further but fails in bootloader installation:
   - `bwrap: Creating new namespace failed: Invalid argument`

This means the current blocker is not package content in the guest image. The blocker is the build/runtime environment in osbuild/bootc install stages on this host.

## What Was Confirmed Working

### 1. arm64 package set inside the image
`Containerfile.bootc` already installs the expected base/networking packages and arm64 firmware bits.
No missing package set was found in the built image definition.

### 2. Cross-arch container emulation on host
`qemu-user-static` installed successfully.
`/proc/sys/fs/binfmt_misc/qemu-aarch64` exists and is enabled.
`podman run --platform linux/arm64 ... uname -m` succeeded (`aarch64`).

### 3. Registry path (after endpoint change)
Registry moved behind Caddy on `registry.fritz.box` (80/443).
Push to `registry.fritz.box/seabird/...` works.
The old `registry.fritz.box:5000` endpoint is no longer reliable/reachable from this host.

### 4. Raw-build orchestration improvements added in repo
- `scripts/build-image.sh` now defaults arm64 raw builds to VM mode.
- Script now performs preflight checks for missing `qemu-system-aarch64` in the selected builder image.
- Script now handles rootless->rootful transfer for custom builder images.
- README documents VM-mode behavior and requirements.
- Added `Containerfile.bootc-image-builder` to build a custom builder image with `qemu-system-aarch64`.

## Builder Images Tested

### Default builder
`quay.io/centos-bootc/bootc-image-builder:latest`
- Lacks `qemu-system-aarch64` by default.
- Now detected early by script preflight (clear error).

### Custom builder (derived)
Built local image from:
- Base: `quay.io/centos-bootc/bootc-image-builder:latest`
- Added: `dnf -y install qemu-system-aarch64`
- Published as: `registry.fritz.box/seabird/bootc-image-builder:arm64-vm`

Result:
- Removes the missing-binary blocker.
- VM mode still fails later with the same QEMU ramdisk startup error.

## Failure Details by Mode

### A) VM mode (`BIB_IN_VM=true`)
Observed with both default and custom builder images.

Key errors:
- `qemu: linux kernel too old to load a ram disk`
- `RuntimeError: QEMU did not become ready`

Context:
- Happens in osbuild pipeline stage `org.osbuild.linux` running `in vm`.
- Indicates VM bootstrap failure before image stage completion.

### B) Host mode (`BIB_IN_VM=false`)
Progresses much further:
- Raw disk truncate/partition/mkfs steps succeed.
- `bootc install to-filesystem` starts and deploys image.

Fails at bootloader support probe:
- `bwrap: Creating new namespace failed: Invalid argument`
- Called from `bootupd --filesystem` probing path.

Interpretation:
- Host mode bypasses VM startup issue, but still hits namespace/bubblewrap constraints in bootc install path.

## SELinux Warning Seen (Non-primary failure)
Repeated warning in logs:
- `Regex version mismatch, expected: 10.46 ... actual: 10.47 ...`

This appears during `org.osbuild.selinux` but did not terminate the pipeline by itself.
Primary abort conditions are still the QEMU readiness failure (VM mode) and bwrap namespace failure (host mode).

## Why This Is "Not Possible" Right Now on This Host

Given current host + toolchain combination:
- VM mode cannot boot the internal QEMU execution environment reliably.
- Host mode cannot complete bootloader install due to namespace creation failure.

So both available raw-image execution paths fail for different low-level runtime reasons, even though image content and registry plumbing are correct.

## Practical Options From Here

1. Run raw-image build on native arm64 hardware.
   - Most likely to avoid both x86_64 VM emulation edge cases and some namespace constraints.

2. Pin/try a different bootc-image-builder/osbuild stack.
   - Use an older known-good tag (instead of `latest`) and retest both modes.

3. Investigate host namespace settings/policies deeply.
   - Focus on why bubblewrap namespace creation fails in bootc install stage.

4. Keep using container image output only (no raw) on this host until one of the above is resolved.

## Files Changed During This Investigation

- `scripts/build-image.sh`
  - arm64 VM default behavior for raw builds
  - preflight check for `qemu-system-aarch64`
  - rootless->rootful transfer handling for custom builder images

- `README.md`
  - VM mode behavior and builder-image requirements
  - commands for building and using custom builder image

- `Containerfile.bootc-image-builder`
  - custom builder recipe installing `qemu-system-aarch64`

## Repro Commands (Current)

Build custom builder image:

```bash
podman build -f Containerfile.bootc-image-builder -t localhost/bootc-image-builder:arm64-vm .
podman tag localhost/bootc-image-builder:arm64-vm registry.fritz.box/seabird/bootc-image-builder:arm64-vm
podman push --tls-verify=false registry.fritz.box/seabird/bootc-image-builder:arm64-vm
```

VM-mode attempt:

```bash
IMAGE_REGISTRY=registry.fritz.box \
BOOTC_IMAGE_BUILDER_IMAGE=registry.fritz.box/seabird/bootc-image-builder:arm64-vm \
BUILD_RAW_IMAGE=true \
./scripts/build-image.sh
```

Host-mode attempt:

```bash
IMAGE_REGISTRY=registry.fritz.box \
BIB_IN_VM=false \
BUILD_RAW_IMAGE=true \
./scripts/build-image.sh
```

Both currently fail as documented above.
