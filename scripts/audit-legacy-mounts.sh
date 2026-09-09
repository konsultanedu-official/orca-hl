#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  echo "LEGACY_AUDIT_FAIL: $*" >&2
  exit 1
}

info() {
  echo "LEGACY_AUDIT_INFO: $*"
}

if [[ "${1:-}" == "--help" || -z "${1:-}" ]]; then
  cat <<'EOF'
Usage: bash scripts/audit-legacy-mounts.sh <container-name-or-id>

Environment:
  DOCKER_USE_SUDO=auto|0|1       auto = direct, then cached sudo; 1 = interactive sudo.

Read-only audit for an older/root-based Orca deployment. The script never starts,
stops, copies, chowns, deletes, or otherwise mutates the target container or data.
Using DOCKER_USE_SUDO=1 may ask for the host user's sudo password.
EOF
  [[ "${1:-}" == "--help" ]] && exit 0
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/docker-access.sh
source "$ROOT/scripts/lib/docker-access.sh"

target="$1"
orca_resolve_docker_access || fail "$ORCA_DOCKER_ACCESS_ERROR"
info "Docker access: $ORCA_DOCKER_ACCESS_MODE"

"${DOCKER_CMD[@]}" inspect "$target" >/dev/null 2>&1 || fail "container not found: $target"

running="$("${DOCKER_CMD[@]}" inspect -f '{{.State.Running}}' "$target")"
user="$("${DOCKER_CMD[@]}" inspect -f '{{if .Config.User}}{{.Config.User}}{{else}}<image-default>{{end}}' "$target")"
image="$("${DOCKER_CMD[@]}" inspect -f '{{.Config.Image}}' "$target")"

info "container: $target"
info "image: $image"
info "configured user: $user"
info "running: $running"

echo
echo '=== Mounts ==='
"${DOCKER_CMD[@]}" inspect -f '{{range .Mounts}}{{printf "%s\t%s\t%s\tRW=%v\n" .Type .Source .Destination .RW}}{{end}}' "$target"

echo
echo '=== Legacy /root mount destinations ==='
legacy_mounts="$("${DOCKER_CMD[@]}" inspect -f '{{range .Mounts}}{{println .Destination}}{{end}}' "$target" | awk '/^\/root(\/|$)/')"
if [[ -n "$legacy_mounts" ]]; then
  printf '%s\n' "$legacy_mounts"
else
  echo '<none>'
fi

echo
echo '=== Candidate state paths ==='
paths=(
  /root/.config/orca
  /root/.config/Orca
  /root/.config/opencode
  /root/.local/share/opencode
  /root/.codex
  /root/.claude
  /root/.agents
  /root/.config/gh
  /root/orca/workspaces
  /projects
)

if [[ "$running" == "true" ]]; then
  for path in "${paths[@]}"; do
    "${DOCKER_CMD[@]}" exec "$target" sh -lc "
      if [ -e '$path' ]; then
        printf '%s\t' '$path'
        stat -c 'uid=%u gid=%g mode=%a type=%F' '$path' 2>/dev/null || true
        du -sh '$path' 2>/dev/null | awk '{print \"size=\" \$1}' || true
      fi
    "
  done
else
  echo 'container is stopped; filesystem ownership/size checks were skipped (the audit will not start it)'
fi

echo
echo '=== Migration map (informational only) ==='
cat <<'EOF'
/root/.config/orca          -> /home/orca/.config/orca
/root/.config/Orca          -> /home/orca/.config/Orca
/root/.config/opencode      -> /home/orca/.config/opencode
/root/.local/share/opencode -> /home/orca/.local/share/opencode
/root/.codex                -> /home/orca/.codex
/root/.claude               -> /home/orca/.claude
/root/.agents               -> /home/orca/.agents
/root/.config/gh            -> /home/orca/.config/gh
/root/orca/workspaces       -> /home/orca/orca/workspaces
/projects                   -> /projects
EOF

if [[ -n "$legacy_mounts" ]]; then
  info "legacy root-based mounts were found; do not attach them blindly to the UID 10001 runtime"
else
  info "no /root mount destinations were found"
fi

printf 'LEGACY_AUDIT_PASS\n'
