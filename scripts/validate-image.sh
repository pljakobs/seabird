#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-${ROOT_DIR}/artifacts}"

IMAGE_REGISTRY="${IMAGE_REGISTRY:-registry.fritz.box:5000}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-seabird/bootc}"
IMAGE_TAG="${IMAGE_TAG:-dev}"
REQUIRED_IMAGE_ARCH="${REQUIRED_IMAGE_ARCH:-arm64}"

if command -v podman >/dev/null 2>&1; then
  ENGINE="podman"
elif command -v docker >/dev/null 2>&1; then
  ENGINE="docker"
else
  echo "ERROR: neither podman nor docker is available" >&2
  exit 1
fi

IMAGE_REF="${IMAGE_REGISTRY}/${IMAGE_REPOSITORY}:${IMAGE_TAG}"

mkdir -p "${ARTIFACT_DIR}"

echo "Validating image with ${ENGINE}: ${IMAGE_REF}"

if ! "${ENGINE}" image inspect "${IMAGE_REF}" >/dev/null 2>&1; then
  echo "ERROR: image not found: ${IMAGE_REF}" >&2
  exit 1
fi

IMAGE_ARCH="$(${ENGINE} image inspect --format '{{.Architecture}}' "${IMAGE_REF}")"
if [[ -n "${REQUIRED_IMAGE_ARCH}" && "${IMAGE_ARCH}" != "${REQUIRED_IMAGE_ARCH}" ]]; then
  echo "ERROR: image architecture '${IMAGE_ARCH}' does not match REQUIRED_IMAGE_ARCH='${REQUIRED_IMAGE_ARCH}'" >&2
  exit 1
fi

HOST_ARCH="$(uname -m)"
case "${HOST_ARCH}" in
  x86_64) HOST_ARCH="amd64" ;;
  aarch64) HOST_ARCH="arm64" ;;
esac

RUNTIME_CHECK_STATUS="passed"
if [[ "${HOST_ARCH}" == "${IMAGE_ARCH}" ]]; then
  "${ENGINE}" run --rm --entrypoint /usr/bin/bash "${IMAGE_REF}" -lc 'cat /etc/os-release >/dev/null'
  "${ENGINE}" run --rm --entrypoint /usr/bin/bash "${IMAGE_REF}" -lc 'command -v nft >/dev/null'
else
  RUNTIME_CHECK_STATUS="skipped (host ${HOST_ARCH} != image ${IMAGE_ARCH})"
fi

if ! "${ENGINE}" image inspect --format '{{index .Config.Labels "io.seabird.channel"}}' "${IMAGE_REF}" | grep -q .; then
  echo "ERROR: missing label io.seabird.channel" >&2
  exit 1
fi

cat > "${ARTIFACT_DIR}/validation-report.txt" <<EOF
status: pass
image: ${IMAGE_REF}
image_arch: ${IMAGE_ARCH}
host_arch: ${HOST_ARCH}
checks:
  - image exists
  - architecture matches ${REQUIRED_IMAGE_ARCH}
  - runtime checks: ${RUNTIME_CHECK_STATUS}
  - required label io.seabird.channel present
EOF

echo "Validation complete. Report written to ${ARTIFACT_DIR}/validation-report.txt"
