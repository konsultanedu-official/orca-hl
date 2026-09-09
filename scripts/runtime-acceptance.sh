#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  echo "ACCEPTANCE_FAIL: $*" >&2
  exit 1
}

warn() {
  echo "ACCEPTANCE_WARN: $*" >&2
}

info() {
  echo "ACCEPTANCE_INFO: $*"
}

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: bash scripts/runtime-acceptance.sh

Environment:
  ENV_FILE=.env
  DEPLOYMENT_MODE=proxy|host
  EXPECTED_VERSION=1.4.198       Optional exact runtime version assertion.
  REQUIRE_GH_AUTH=0|1            Fail when GitHub CLI is unauthenticated when set to 1.
  HEALTH_TIMEOUT=120             Seconds to wait for Docker health to become healthy.
  LOG_LOOKBACK=15m               Docker log window scanned for fatal patterns.
  DOCKER_USE_SUDO=auto|0|1       auto = direct, then cached sudo; 1 = interactive sudo.

The script is read-only against a running deployment. It does not install skills,
authenticate accounts, mutate Git state, start agents, or change container state.
Using DOCKER_USE_SUDO=1 may ask for the host user's sudo password.
EOF
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=scripts/lib/docker-access.sh
source "$ROOT/scripts/lib/docker-access.sh"

ENV_FILE="${ENV_FILE:-.env}"
DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-proxy}"
EXPECTED_VERSION="${EXPECTED_VERSION:-}"
REQUIRE_GH_AUTH="${REQUIRE_GH_AUTH:-0}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"
LOG_LOOKBACK="${LOG_LOOKBACK:-15m}"

[[ -f "$ENV_FILE" ]] || fail "env file not found: $ENV_FILE"
[[ "$HEALTH_TIMEOUT" =~ ^[0-9]+$ ]] || fail "HEALTH_TIMEOUT must be an integer number of seconds"

orca_resolve_docker_access || fail "$ORCA_DOCKER_ACCESS_ERROR"
"${DOCKER_CMD[@]}" compose version >/dev/null 2>&1 || fail "Docker Compose v2 is unavailable for Docker access mode: $ORCA_DOCKER_ACCESS_MODE"
info "Docker access: $ORCA_DOCKER_ACCESS_MODE"

case "$DEPLOYMENT_MODE" in
  proxy) compose_files=(-f docker-compose.yml) ;;
  host) compose_files=(-f docker-compose.yml -f docker-compose.host.yml) ;;
  *) fail "DEPLOYMENT_MODE must be proxy or host" ;;
esac

compose=("${DOCKER_CMD[@]}" compose --env-file "$ENV_FILE" "${compose_files[@]}")
"${compose[@]}" config >/dev/null || fail "Compose model is invalid"

cid="$("${compose[@]}" ps -q orca)"
[[ -n "$cid" ]] || fail "Orca service container was not found"

running="$("${DOCKER_CMD[@]}" inspect -f '{{.State.Running}}' "$cid")"
[[ "$running" == "true" ]] || fail "Orca container is not running"
info "container: $cid"

health="$("${DOCKER_CMD[@]}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")"
if [[ "$health" == "none" ]]; then
  warn "container has no health status"
elif [[ "$health" != "healthy" ]]; then
  info "waiting up to ${HEALTH_TIMEOUT}s for container health (current: $health)"
  deadline=$((SECONDS + HEALTH_TIMEOUT))
  while (( SECONDS < deadline )); do
    health="$("${DOCKER_CMD[@]}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")"
    [[ "$health" == "healthy" ]] && break
    [[ "$health" == "unhealthy" ]] && fail "container became unhealthy"
    running="$("${DOCKER_CMD[@]}" inspect -f '{{.State.Running}}' "$cid")"
    [[ "$running" == "true" ]] || fail "Orca container stopped while waiting for health"
    sleep 2
  done
  [[ "$health" == "healthy" ]] || fail "container health did not become healthy within ${HEALTH_TIMEOUT}s (last: $health)"
  info "health: healthy"
else
  info "health: healthy"
fi

uid="$("${compose[@]}" exec -T orca id -u)"
[[ "$uid" == "10001" ]] || fail "runtime UID is $uid; expected non-root UID 10001"

home="$("${compose[@]}" exec -T orca sh -lc 'printf %s "$HOME"')"
[[ "$home" == "/home/orca" ]] || fail "runtime HOME is $home; expected /home/orca"

runtime_version="$("${compose[@]}" exec -T orca sh -lc 'printf %s "${ORCA_IMAGE_VERSION:-}"')"
[[ -n "$runtime_version" ]] || fail "ORCA_IMAGE_VERSION is missing inside container"
info "Orca image version: $runtime_version"
if [[ -n "$EXPECTED_VERSION" && "$runtime_version" != "$EXPECTED_VERSION" ]]; then
  fail "runtime version $runtime_version does not match EXPECTED_VERSION=$EXPECTED_VERSION"
fi

for cmd in git node npm npx gh jq python3 codex claude opencode orca; do
  "${compose[@]}" exec -T orca sh -lc "command -v '$cmd' >/dev/null 2>&1" || fail "missing runtime command: $cmd"
done

"${compose[@]}" exec -T orca codex app-server --help >/dev/null || fail "codex app-server is unavailable"
"${compose[@]}" exec -T orca claude --help >/dev/null || fail "Claude Code CLI is unavailable"
"${compose[@]}" exec -T orca opencode --help >/dev/null || fail "OpenCode CLI is unavailable"

for dir in \
  /home/orca/.config/orca \
  /home/orca/.config/Orca \
  /home/orca/.config/opencode \
  /home/orca/.local/share/opencode \
  /home/orca/.codex \
  /home/orca/.claude \
  /home/orca/.agents \
  /home/orca/.config/gh \
  /home/orca/orca/workspaces \
  /projects; do
  "${compose[@]}" exec -T orca sh -lc "test -d '$dir' && test -w '$dir'" || fail "persistent path missing or not writable: $dir"
done

root_mounts="$("${DOCKER_CMD[@]}" inspect -f '{{range .Mounts}}{{println .Destination}}{{end}}' "$cid" | awk '/^\/root(\/|$)/')"
if [[ -n "$root_mounts" ]]; then
  printf '%s\n' "$root_mounts" >&2
  fail "legacy /root mount destinations are still attached to the non-root image"
fi

"${compose[@]}" exec -T orca orca status --json >/dev/null || fail "orca status --json failed"
"${compose[@]}" exec -T orca orca terminal list --json >/dev/null || fail "orca terminal list --json failed"
"${compose[@]}" exec -T orca orca skills get orca-cli >/dev/null || fail "bundled Orca CLI skill guide unavailable"

if "${compose[@]}" exec -T orca gh auth status >/dev/null 2>&1; then
  info "GitHub CLI authentication: authenticated"
else
  if [[ "$REQUIRE_GH_AUTH" == "1" ]]; then
    fail "GitHub CLI is not authenticated"
  elif [[ "$REQUIRE_GH_AUTH" == "0" ]]; then
    warn "GitHub CLI is not authenticated; Orca GitHub issue/PR features may report 'gh auth login' until configured"
  else
    fail "REQUIRE_GH_AUTH must be 0 or 1"
  fi
fi

logs="$("${DOCKER_CMD[@]}" logs --since "$LOG_LOOKBACK" "$cid" 2>&1 || true)"
for pattern in \
  'spawn codex ENOENT' \
  'Exec format error' \
  'Permission denied' \
  'EACCES' \
  'Orca server exited before readiness'; do
  if grep -Fq "$pattern" <<<"$logs"; then
    fail "fatal runtime log pattern detected in last $LOG_LOOKBACK: $pattern"
  fi
done

if grep -Fq 'gh auth login' <<<"$logs"; then
  warn "runtime logs contain GitHub authentication prompts; this is expected until gh is authenticated"
fi

info "non-root UID: $uid"
info "HOME: $home"
info "persistent paths: writable"
info "legacy /root mounts: none"
info "Orca CLI/readiness surface: operational"
printf 'RUNTIME_ACCEPTANCE_PASS\n'
