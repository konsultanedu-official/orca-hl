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
  DOCKER_USE_SUDO=auto|0|1       auto = direct, then cached sudo; 1 = interactive sudo.
  ALLOW_EXAMPLE_PAIRING=0|1      Default: 0. Test-only escape hatch for example.com.

Compose interpolation follows normal Docker Compose precedence. Values supplied as
exported/inline environment variables therefore override the env file for this run.
Bare shell assignments on separate lines are not exported and do not edit .env.

The script is read-only. It does not pull, start, stop, mutate, or authenticate anything.
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
DEPLOYMENT_TIER="${DEPLOYMENT_TIER:-canary}"
CHECK_IMAGE="${CHECK_IMAGE:-1}"
ALLOW_EXAMPLE_PAIRING="${ALLOW_EXAMPLE_PAIRING:-0}"

case "$ALLOW_EXAMPLE_PAIRING" in
  0|1) ;;
  *) fail "ALLOW_EXAMPLE_PAIRING must be 0 or 1" ;;
esac

orca_resolve_docker_access || fail "$ORCA_DOCKER_ACCESS_ERROR"
"${DOCKER_CMD[@]}" compose version >/dev/null 2>&1 || fail "Docker Compose v2 is unavailable for Docker access mode: $ORCA_DOCKER_ACCESS_MODE"
info "Docker access: $ORCA_DOCKER_ACCESS_MODE"

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

compose=("${DOCKER_CMD[@]}" compose --env-file "$ENV_FILE" "${compose_files[@]}")

info "validating Compose model ($DEPLOYMENT_MODE)"
"${compose[@]}" config >/dev/null || fail "Compose model is invalid"

# Resolve the interpolation environment using Docker Compose itself so preflight
# validates the same values that Compose will actually use. This avoids a split
# source of truth between .env and exported/inline overrides.
compose_environment="$("${compose[@]}" config --environment)" || fail "could not resolve effective Compose environment"

effective_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' <<<"$compose_environment"
}

image="$("${compose[@]}" config --images | awk 'NF {print; exit}')"
[[ -n "$image" ]] || fail "could not resolve Orca image from Compose"
info "resolved image: $image"

if [[ "$DEPLOYMENT_TIER" == "production" && "$image" == *":latest" ]]; then
  fail "production must use an exact tested tag, not :latest"
fi

if [[ "$DEPLOYMENT_TIER" == "canary" ]]; then
  if [[ "$image" == *":latest" ]]; then
    warn "canary uses moving tag $image; prefer an exact tag for the first migration/reproducibility test"
  else
    info "canary image is pinned for reproducibility: $image"
  fi
fi

pairing="$(effective_value ORCA_PAIRING_ADDRESS)"
[[ -n "$pairing" ]] || fail "ORCA_PAIRING_ADDRESS is empty or missing from the effective Compose environment"
case "$pairing" in
  ws://*|wss://*) ;;
  *) warn "ORCA_PAIRING_ADDRESS does not start with ws:// or wss://: $pairing" ;;
esac

if [[ "$ALLOW_EXAMPLE_PAIRING" != "1" && "$pairing" =~ ^wss?://([^/:]+\.)?example\.com([/:]|$) ]]; then
  fail "ORCA_PAIRING_ADDRESS still uses example.com placeholder: $pairing"
fi

if [[ "$DEPLOYMENT_MODE" == "host" ]]; then
  bind="$(effective_value ORCA_BIND_ADDRESS)"
  bind="${bind:-127.0.0.1}"
  if [[ "$bind" == "0.0.0.0" || "$bind" == "::" ]]; then
    warn "host publishing is bound publicly ($bind); prefer 127.0.0.1 behind aaPanel/Nginx unless public binding is intentional"
  fi
fi

if [[ "$CHECK_IMAGE" == "1" ]]; then
  "${DOCKER_CMD[@]}" buildx version >/dev/null 2>&1 || fail "docker buildx is required for registry manifest inspection"
  info "inspecting registry manifest for $image"
  manifest="$("${DOCKER_CMD[@]}" buildx imagetools inspect "$image" 2>&1)" || {
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
