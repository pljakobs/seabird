#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="${BEACON_LOG_DIR:-${ROOT_DIR}/artifacts/beacon}"
PORT="${BEACON_PORT:-8080}"
IMAGE="${BEACON_IMAGE:-docker.io/library/python:3.12-alpine}"
CONTAINER_NAME="${BEACON_CONTAINER_NAME:-seabird-beacon-listener}"

mkdir -p "${LOG_DIR}"

podman pull "${IMAGE}" >/dev/null
podman rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

exec podman run --name "${CONTAINER_NAME}" --rm \
  -p "${PORT}:8080" \
  -e BEACON_PORT=8080 \
  -e BEACON_LOG_DIR=/logs \
  -v "${ROOT_DIR}/scripts/host/beacon_listener.py:/app/beacon_listener.py:ro,Z" \
  -v "${LOG_DIR}:/logs:Z" \
  "${IMAGE}" \
  python /app/beacon_listener.py
