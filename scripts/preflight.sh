#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  echo "PREFLIGHT_FAIL: $*" >&2
  exit 1
}

warn() {
  echo "PREFLIGHT_WARN: $*" >&2
}

info() {
  echo "PREFLIGHT_INFO: $*"
}

if [[ "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: bash scripts/preflight.sh

Environment:
  ENV_FILE=.env                  Compose env file to validate.
  DEPLOYMENT_MODE=proxy|host     proxy = Coolify/Traefik; host = aaPanel/plain Docker.
  DEPLOYMENT_TIER=canary|production
  CHECK_IMAGE=1|0                Inspect the configured image manifest in its registry.

The script is read-only. It does not pull, start, stop, mutate, or authenticate anything.
EOF
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ENV_FILE="${ENV_FILE:-.env}"
DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-proxy}"
DEPLOYMENT_TIER="${DEPLOYMENT_TIER:-canary}"
CHECK_IMAGE="${CHECK_IMAGE:-1}"

command -v docker >/dev/null 2>&1 || fail "docker CLI is not installed"
docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable"
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is unavailable"

[[ -f "$ENV_FILE" ]] || fail "env file not found: $ENV_FILE (copy .env.example first)"

case "$DEPLOYMENT_MODE" in
  proxy)
    compose_files=(-f docker-compose.yml)
    ;;
  host)
    compose_files=(-f docker-compose.yml -f docker-compose.host.yml)
    ;;
  *)
    fail "DEPLOYMENT_MODE must be proxy or host"
    ;;
esac

case "$DEPLOYMENT_TIER" in
  canary|production) ;;
  *) fail "DEPLOYMENT_TIER must be canary or production" ;;
esac

compose=(docker compose --env-file "$ENV_FILE" "${compose_files[@]}")

info "validating Compose model ($DEPLOYMENT_MODE)"
"${compose[@]}" config >/dev/null || fail "Compose model is invalid"

image="$("${compose[@]}" config --images | awk 'NF {print; exit}')"
[[ -n "$image" ]] || fail "could not resolve Orca image from Compose"
info "resolved image: $image"

if [[ "$DEPLOYMENT_TIER" == "production" && "$image" == *":latest" ]]; then
  fail "production must use an exact tested tag, not :latest"
fi

if [[ "$DEPLOYMENT_TIER" == "canary" && "$image" != *":latest" ]]; then
  warn "canary is pinned to $image; this is valid but will not follow promoted upstream releases automatically"
fi

pairing="$(awk -F= '/^[[:space:]]*ORCA_PAIRING_ADDRESS=/{sub(/^[^=]*=/, ""); print; exit}' "$ENV_FILE")"
[[ -n "$pairing" ]] || fail "ORCA_PAIRING_ADDRESS is empty or missing in $ENV_FILE"
case "$pairing" in
  ws://*|wss://*) ;;
  *) warn "ORCA_PAIRING_ADDRESS does not start with ws:// or wss://: $pairing" ;;
esac

if [[ "$DEPLOYMENT_MODE" == "host" ]]; then
  bind="$(awk -F= '/^[[:space:]]*ORCA_BIND_ADDRESS=/{sub(/^[^=]*=/, ""); print; exit}' "$ENV_FILE")"
  bind="${bind:-127.0.0.1}"
  if [[ "$bind" == "0.0.0.0" || "$bind" == "::" ]]; then
    warn "host publishing is bound publicly ($bind); prefer 127.0.0.1 behind aaPanel/Nginx unless public binding is intentional"
  fi
fi

if [[ "$CHECK_IMAGE" == "1" ]]; then
  docker buildx version >/dev/null 2>&1 || fail "docker buildx is required for registry manifest inspection"
  info "inspecting registry manifest for $image"
  manifest="$(docker buildx imagetools inspect "$image" 2>&1)" || {
    printf '%s\n' "$manifest" >&2
    fail "configured image manifest is not reachable"
  }

  if ! grep -q 'linux/amd64' <<<"$manifest"; then
    warn "manifest inspection did not report linux/amd64"
  fi
  if ! grep -q 'linux/arm64' <<<"$manifest"; then
    warn "manifest inspection did not report linux/arm64"
  fi
elif [[ "$CHECK_IMAGE" != "0" ]]; then
  fail "CHECK_IMAGE must be 1 or 0"
fi

info "deployment tier: $DEPLOYMENT_TIER"
info "pairing address: $pairing"
printf 'PREFLIGHT_PASS\n'
