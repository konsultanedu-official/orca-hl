#!/usr/bin/env bash
set -Eeuo pipefail

ORCA_APP="/opt/orca/squashfs-root/AppRun"

if [[ "${1:-}" != "serve" ]]; then
  exec "$@"
fi
shift || true

port="${ORCA_PORT:-6768}"
args=(serve --port "$port")

if [[ -n "${ORCA_PAIRING_ADDRESS:-}" ]]; then
  args+=(--pairing-address "$ORCA_PAIRING_ADDRESS")
fi

if [[ "${ORCA_JSON_READY:-1}" == "1" ]]; then
  args+=(--json)
fi

exec "$ORCA_APP" "${args[@]}" "$@"
