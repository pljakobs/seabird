# seabird OS

Standalone Fedora bootc image for the seabird CM4 appliance.

## Structure

This repo is self-contained. The image is built from a small shared core stage in [Containerfile.bootc](Containerfile.bootc) and a router-specific overlay for:

- SSH bootstrap
- first-boot beacon delivery
- networking and bring-up tools
- CM4 bootc raw-image generation

The build scripts default to the local registry at `registry.fritz.box:5000`.

## Build

```bash
./scripts/build-image.sh
```

By default this builds an `arm64` image suitable for the CM4 target. To override the registry or tag:

```bash
IMAGE_REGISTRY=registry.fritz.box:5000 IMAGE_REPOSITORY=seabird/bootc IMAGE_TAG=dev ./scripts/build-image.sh
```

## Validate

```bash
./scripts/validate-image.sh
```

## Raw image

```bash
BUILD_RAW_IMAGE=true ./scripts/build-image.sh
```

For arm64 raw images, the builder now defaults to `bootc-image-builder --in-vm`, which uses a QEMU aarch64 VM for the disk-image stage. Override that behavior with `BIB_IN_VM=false` if you want host mode instead.

When `BIB_IN_VM=true` for `TARGET_ARCH=arm64`, the selected `BOOTC_IMAGE_BUILDER_IMAGE` must include `qemu-system-aarch64`. The default `quay.io/centos-bootc/bootc-image-builder:latest` currently does not, so the script now exits early with a clear error instead of failing later inside osbuild.

To build a compatible local builder image:

```bash
podman build -f Containerfile.bootc-image-builder -t localhost/bootc-image-builder:arm64-vm .
```

Then use it for raw builds:

```bash
BOOTC_IMAGE_BUILDER_IMAGE=localhost/bootc-image-builder:arm64-vm BUILD_RAW_IMAGE=true ./scripts/build-image.sh
```

The raw image builder uses the arch-specific config in `config/image-builder-arm64.toml` when present, and falls back to the shared bootc defaults baked into the image.
