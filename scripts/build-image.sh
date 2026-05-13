#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-${ROOT_DIR}/artifacts}"

CONTAINERFILE="${CONTAINERFILE:-${ROOT_DIR}/Containerfile.bootc}"
CONTEXT_DIR="${CONTEXT_DIR:-${ROOT_DIR}}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-registry.fritz.box:5000}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-seabird/bootc}"
IMAGE_TAG="${IMAGE_TAG:-dev}"
CHANNEL="${CHANNEL:-dev}"
PUSH_IMAGE="${PUSH_IMAGE:-false}"
BUILD_RAW_IMAGE="${BUILD_RAW_IMAGE:-false}"
RAW_IMAGE_TYPE="${RAW_IMAGE_TYPE:-raw}"
BOOTC_IMAGE_BUILDER_IMAGE="${BOOTC_IMAGE_BUILDER_IMAGE:-quay.io/centos-bootc/bootc-image-builder:latest}"
BOOTC_IMAGE_BUILDER_CONFIG="${BOOTC_IMAGE_BUILDER_CONFIG:-}"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-${HOME}/.ssh/id_ed25519.pub}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
PODMAN_SECURITY_OPT="${PODMAN_SECURITY_OPT:-label=disable}"
BOOTC_ROOTFS="${BOOTC_ROOTFS:-ext4}"
BIB_CHOWN_OUTPUT="${BIB_CHOWN_OUTPUT:-false}"
BIB_IN_VM="${BIB_IN_VM:-}"
BIB_LEGACY_CLI="${BIB_LEGACY_CLI:-false}"
BUILD_HOST_IP="${BUILD_HOST_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
FIRSTBOOT_BEACON_URL="${FIRSTBOOT_BEACON_URL:-}"
TARGET_OS="${TARGET_OS:-linux}"
TARGET_ARCH="${TARGET_ARCH:-arm64}"
TARGET_PLATFORM="${TARGET_PLATFORM:-${TARGET_OS}/${TARGET_ARCH}}"
REQUIRED_IMAGE_ARCH="${REQUIRED_IMAGE_ARCH:-${TARGET_ARCH}}"
CHECK_CROSS_BUILD="${CHECK_CROSS_BUILD:-true}"

case "${TARGET_ARCH}" in
  arm64) BIB_TARGET_ARCH="aarch64" ;;
  amd64) BIB_TARGET_ARCH="x86_64" ;;
  *)
    echo "ERROR: unsupported TARGET_ARCH '${TARGET_ARCH}' for bootc-image-builder --target-arch mapping" >&2
    exit 1
    ;;
esac

if [[ -z "${BIB_IN_VM}" ]]; then
  if [[ "${BUILD_RAW_IMAGE}" == "true" && "${TARGET_ARCH}" == "arm64" ]]; then
    BIB_IN_VM="true"
  else
    BIB_IN_VM="false"
  fi
fi

if [[ -z "${BOOTC_IMAGE_BUILDER_CONFIG}" ]]; then
  BOOTC_IMAGE_BUILDER_CONFIG="${ROOT_DIR}/config/image-builder-${TARGET_ARCH}.toml"
fi

if command -v podman >/dev/null 2>&1; then
  ENGINE="podman"
elif command -v docker >/dev/null 2>&1; then
  ENGINE="docker"
else
  echo "ERROR: neither podman nor docker is available" >&2
  exit 1
fi

if [[ ! -f "${CONTAINERFILE}" ]]; then
  echo "ERROR: Containerfile not found at ${CONTAINERFILE}" >&2
  exit 1
fi

if [[ ! -f "${SSH_PUBKEY_FILE}" ]]; then
  echo "ERROR: SSH public key file not found: ${SSH_PUBKEY_FILE}" >&2
  exit 1
fi

mkdir -p "${ARTIFACT_DIR}"

COMMIT_SHA="$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
SOURCE_URL="$(git -C "${ROOT_DIR}" config --get remote.origin.url 2>/dev/null || echo unknown)"
SSH_PUBKEY_CONTENT="$(tr -d '\n' < "${SSH_PUBKEY_FILE}")"

if [[ -z "${SSH_PUBKEY_CONTENT}" ]]; then
  echo "ERROR: SSH public key file is empty: ${SSH_PUBKEY_FILE}" >&2
  exit 1
fi

if [[ -z "${FIRSTBOOT_BEACON_URL}" && -n "${BUILD_HOST_IP}" ]]; then
  FIRSTBOOT_BEACON_URL="http://${BUILD_HOST_IP}:8080/boot"
fi

IMAGE_REF="${IMAGE_REGISTRY}/${IMAGE_REPOSITORY}:${IMAGE_TAG}"

HOST_ARCH="$(uname -m)"
case "${HOST_ARCH}" in
  x86_64) HOST_ARCH="amd64" ;;
  aarch64) HOST_ARCH="arm64" ;;
esac

if [[ "${CHECK_CROSS_BUILD}" == "true" && "${HOST_ARCH}" != "${TARGET_ARCH}" ]]; then
  echo "Checking cross-arch runtime support for ${TARGET_PLATFORM} on host ${HOST_ARCH}"
  if ! "${ENGINE}" run --rm --platform "${TARGET_PLATFORM}" --entrypoint /bin/sh quay.io/fedora/fedora-bootc:latest -c 'true' >/dev/null 2>&1; then
    echo "ERROR: cross-arch container execution is not available (${HOST_ARCH} -> ${TARGET_ARCH})." >&2
    echo "Install/register binfmt emulation, then retry:" >&2
    echo "  sudo podman run --rm --privileged docker.io/tonistiigi/binfmt --install ${TARGET_ARCH}" >&2
    echo "If registration succeeds but arm64 containers still crash (e.g. exit 139), build on native ${TARGET_ARCH} hardware." >&2
    exit 1
  fi
fi

echo "Building image with ${ENGINE}: ${IMAGE_REF}"
BUILD_CMD=("${ENGINE}" build)
if [[ "${ENGINE}" == "podman" && -n "${PODMAN_SECURITY_OPT}" ]]; then
  BUILD_CMD+=(--security-opt "${PODMAN_SECURITY_OPT}")
fi
if [[ -n "${TARGET_PLATFORM}" ]]; then
  BUILD_CMD+=(--platform "${TARGET_PLATFORM}")
fi

"${BUILD_CMD[@]}" \
  --file "${CONTAINERFILE}" \
  --tag "${IMAGE_REF}" \
  --build-arg "SSH_PUBKEY=${SSH_PUBKEY_CONTENT}" \
  --build-arg "ADMIN_USERNAME=${ADMIN_USERNAME}" \
  --build-arg "FIRSTBOOT_BEACON_URL=${FIRSTBOOT_BEACON_URL}" \
  --label "org.opencontainers.image.created=${BUILD_DATE}" \
  --label "org.opencontainers.image.revision=${COMMIT_SHA}" \
  --label "org.opencontainers.image.source=${SOURCE_URL}" \
  --label "org.opencontainers.image.version=${IMAGE_TAG}" \
  --label "io.seabird.channel=${CHANNEL}" \
  "${CONTEXT_DIR}"

IMAGE_ARCH="$(${ENGINE} image inspect --format '{{.Architecture}}' "${IMAGE_REF}")"
if [[ -n "${REQUIRED_IMAGE_ARCH}" && "${IMAGE_ARCH}" != "${REQUIRED_IMAGE_ARCH}" ]]; then
  echo "ERROR: built image architecture '${IMAGE_ARCH}' does not match REQUIRED_IMAGE_ARCH='${REQUIRED_IMAGE_ARCH}'" >&2
  exit 1
fi

if [[ "${PUSH_IMAGE}" == "true" ]]; then
  echo "Pushing image: ${IMAGE_REF}"
  "${ENGINE}" push "${IMAGE_REF}"
fi

if [[ "${BUILD_RAW_IMAGE}" == "true" ]]; then
  if [[ "${ENGINE}" != "podman" ]]; then
    echo "ERROR: BUILD_RAW_IMAGE=true currently requires podman." >&2
    exit 1
  fi

  if [[ "${BIB_IN_VM}" == "true" && "${TARGET_ARCH}" == "arm64" ]]; then
    if ! podman run --rm --entrypoint /bin/sh "${BOOTC_IMAGE_BUILDER_IMAGE}" -c 'command -v qemu-system-aarch64 >/dev/null'; then
      echo "ERROR: BOOTC_IMAGE_BUILDER_IMAGE (${BOOTC_IMAGE_BUILDER_IMAGE}) does not provide qemu-system-aarch64 required for BIB_IN_VM=true with TARGET_ARCH=arm64." >&2
      echo "Use a builder image that includes qemu-system-aarch64, or set BIB_IN_VM=false to use host mode." >&2
      exit 1
    fi
  fi

  mkdir -p "${ARTIFACT_DIR}/rpmmd" "${ARTIFACT_DIR}/store"

  PODMAN_CMD=(podman)
  ROOTLESS="$(podman info --format '{{.Host.Security.Rootless}}')"
  if [[ "${ROOTLESS}" == "true" ]]; then
    if sudo -n true >/dev/null 2>&1; then
      PODMAN_CMD=(sudo podman)
    else
      echo "ERROR: rootful podman is required for raw image export. Configure passwordless sudo or run this script as root." >&2
      exit 1
    fi
  fi

  BUILDER_IMAGE_REF="${IMAGE_REF}"

  # If a custom builder image is present only in rootless storage (for example
  # localhost/* tags), copy it into rootful storage before running BIB.
  if [[ "${ROOTLESS}" == "true" ]]; then
    if ! "${PODMAN_CMD[@]}" image exists "${BOOTC_IMAGE_BUILDER_IMAGE}"; then
      if podman image exists "${BOOTC_IMAGE_BUILDER_IMAGE}"; then
        TRANSFER_BUILDER_ARCHIVE="${ARTIFACT_DIR}/builder-image-transfer-${IMAGE_TAG}.ociarchive"
        echo "Transferring ${BOOTC_IMAGE_BUILDER_IMAGE} from rootless to rootful podman store"
        podman save --format oci-archive -o "${TRANSFER_BUILDER_ARCHIVE}" "${BOOTC_IMAGE_BUILDER_IMAGE}"
        "${PODMAN_CMD[@]}" load -i "${TRANSFER_BUILDER_ARCHIVE}" >/dev/null
        rm -f "${TRANSFER_BUILDER_ARCHIVE}"
      fi
    fi
  fi

  # bootc-image-builder runs rootful. If the source image was built rootless,
  # transfer it into rootful storage before invoking the builder.
  if [[ "${ROOTLESS}" == "true" ]]; then
    if ! "${PODMAN_CMD[@]}" image exists "${BUILDER_IMAGE_REF}"; then
      TRANSFER_ARCHIVE="${ARTIFACT_DIR}/image-transfer-${IMAGE_TAG}.ociarchive"
      echo "Transferring ${IMAGE_REF} from rootless to rootful podman store"
      podman save --format oci-archive -o "${TRANSFER_ARCHIVE}" "${IMAGE_REF}"
      "${PODMAN_CMD[@]}" load -i "${TRANSFER_ARCHIVE}" >/dev/null
      rm -f "${TRANSFER_ARCHIVE}"
    fi
  fi

  GRAPH_ROOT="$("${PODMAN_CMD[@]}" info --format '{{.Store.GraphRoot}}')"

  echo "Creating ${RAW_IMAGE_TYPE} artifact from ${BUILDER_IMAGE_REF}"
  BIB_ARGS=(--type "${RAW_IMAGE_TYPE}" --target-arch "${BIB_TARGET_ARCH}" --rootfs "${BOOTC_ROOTFS}" --output /output)
  if [[ "${BIB_LEGACY_CLI}" != "true" ]]; then
    BIB_ARGS=(build "${BIB_ARGS[@]}")
  fi
  if [[ "${BIB_IN_VM}" == "true" ]]; then
    echo "Using bootc-image-builder in VM mode for the raw image step"
    BIB_ARGS+=(--in-vm)
  fi
  if [[ -f "${BOOTC_IMAGE_BUILDER_CONFIG}" ]]; then
    BIB_ARGS+=(--config "/host/config/$(basename "${BOOTC_IMAGE_BUILDER_CONFIG}")")
  fi
  if [[ "${BIB_CHOWN_OUTPUT}" == "true" ]]; then
    echo "WARNING: BIB_CHOWN_OUTPUT=true is currently ignored due to bootc-image-builder chown failures; leaving ownership unchanged." >&2
  fi
  BIB_ARGS+=("${BUILDER_IMAGE_REF}")

  # Write a temporary registries.conf so BIB can pull from the (possibly insecure) local registry
  BIB_REGISTRIES_CONF="${ARTIFACT_DIR}/bib-registries.conf"
  REGISTRY_HOST="${IMAGE_REGISTRY%%/*}"
  cat > "${BIB_REGISTRIES_CONF}" <<REGEOF
unqualified-search-registries = []
[[registry]]
prefix = "${REGISTRY_HOST}"
location = "${REGISTRY_HOST}"
insecure = true
REGEOF

  # Create environment file with bwrap disable flags to ensure they propagate through all subprocesses
  OSBUILD_ENV_FILE="${ARTIFACT_DIR}/.osbuild-env"
  cat > "${OSBUILD_ENV_FILE}" <<ENVEOF
BOOTUPD_BWRAP=0
OSBUILD_BWRAP=0
LIBOSTREE_BWRAP=0
ENVEOF

  if ! "${PODMAN_CMD[@]}" run --rm --privileged \
    --userns=host \
    --security-opt label=disable \
    --env-file "${OSBUILD_ENV_FILE}" \
    -v "${GRAPH_ROOT}:/var/lib/containers/storage:Z" \
    -v "${ARTIFACT_DIR}:/output:Z" \
    -v "${ROOT_DIR}/config:/host/config:Z" \
    -v "${ARTIFACT_DIR}/rpmmd:/rpmmd:Z" \
    -v "${ARTIFACT_DIR}/store:/store:Z" \
    -v "${BIB_REGISTRIES_CONF}:/etc/containers/registries.conf:ro,Z" \
    "${BOOTC_IMAGE_BUILDER_IMAGE}" \
    "${BIB_ARGS[@]}"; then
    if [[ "${BIB_IN_VM}" != "true" ]]; then
      echo "ERROR: raw image build failed. If logs include 'bwrap: Creating new namespace failed' or 'kernel too old to load ramdisk', try BIB_IN_VM=true or check if the host supports user namespaces (sysctl -a | grep user_namespace)." >&2
    fi
    exit 1
  fi

  RAW_IMAGE_PATH="$(find "${ARTIFACT_DIR}" -maxdepth 3 -type f \( -name '*.raw' -o -name '*.img' -o -name '*.raw.xz' -o -name '*.img.xz' \) | head -n 1 || true)"
  if [[ -z "${RAW_IMAGE_PATH}" ]]; then
    echo "WARNING: raw image build completed but no image file was auto-detected in ${ARTIFACT_DIR}" >&2
  else
    printf '%s\n' "${RAW_IMAGE_PATH}" > "${ARTIFACT_DIR}/raw-image-path.txt"
    echo "Raw image artifact: ${RAW_IMAGE_PATH}"
  fi
fi

IMAGE_ID="$("${ENGINE}" image inspect --format '{{.Id}}' "${IMAGE_REF}")"
IMAGE_DIGEST="$("${ENGINE}" image inspect --format '{{index .RepoDigests 0}}' "${IMAGE_REF}" 2>/dev/null || true)"

cat > "${ARTIFACT_DIR}/build-metadata.json" <<EOF
{
  "image_ref": "${IMAGE_REF}",
  "image_id": "${IMAGE_ID}",
  "image_digest": "${IMAGE_DIGEST}",
  "image_arch": "${IMAGE_ARCH}",
  "target_platform": "${TARGET_PLATFORM}",
  "firstboot_beacon_url": "${FIRSTBOOT_BEACON_URL}",
  "channel": "${CHANNEL}",
  "commit_sha": "${COMMIT_SHA}",
  "build_date": "${BUILD_DATE}",
  "source": "${SOURCE_URL}",
  "engine": "${ENGINE}"
}
EOF

printf '%s\n' "${IMAGE_REF}" > "${ARTIFACT_DIR}/image-ref.txt"
printf '%s\n' "${IMAGE_DIGEST}" > "${ARTIFACT_DIR}/image-digest.txt"

echo "Build complete. Artifacts in ${ARTIFACT_DIR}"
