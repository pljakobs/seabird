#!/usr/bin/env bash
# Treat transient registry/network pull errors as non-fatal for podman auto-update.
# Keep all other failures fatal so genuine issues are still surfaced.
set -euo pipefail

TMP_OUT="$(mktemp /tmp/podman-auto-update.XXXXXX)"
cleanup() {
    rm -f "${TMP_OUT}"
}
trap cleanup EXIT

if /usr/bin/podman auto-update >"${TMP_OUT}" 2>&1; then
    cat "${TMP_OUT}"
    exit 0
fi

rc=$?
cat "${TMP_OUT}"

if [[ ${rc} -eq 125 ]] && grep -Eiq \
    'no route to host|network is unreachable|i/o timeout|TLS handshake timeout|Temporary failure in name resolution|context deadline exceeded|connection reset by peer' \
    "${TMP_OUT}"; then
    echo "seabird: podman auto-update hit transient network/registry errors; treating run as non-fatal." >&2
    exit 0
fi

exit "${rc}"
