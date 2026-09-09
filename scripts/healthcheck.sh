#!/usr/bin/env bash
set -Eeuo pipefail

cli="${HOME:-/home/orca}/.local/bin/orca"

if [[ -x "$cli" ]]; then
  timeout 8 "$cli" status --json >/dev/null 2>&1
  exit $?
fi

# During first startup the managed CLI shim may not exist yet.
pgrep -f '/opt/orca/squashfs-root/AppRun.*serve' >/dev/null
