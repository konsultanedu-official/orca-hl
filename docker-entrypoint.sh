#!/usr/bin/env bash
set -Eeuo pipefail

ORCA_APP="/opt/orca/squashfs-root/AppRun"

bootstrap_opencode_9router() {
  local base_url="${NINEROUTER_BASE_URL:-}"
  local api_key="${NINEROUTER_API_KEY:-}"

  if [[ -z "$base_url" && -z "$api_key" ]]; then
    return 0
  fi

  if [[ -z "$base_url" || -z "$api_key" ]]; then
    echo "WARNING: NINEROUTER_BASE_URL and NINEROUTER_API_KEY must both be set; skipping OpenCode 9Router bootstrap." >&2
    return 0
  fi

  local config_dir="${HOME:-/home/orca}/.config/opencode"
  local config_file="$config_dir/opencode.json"

  # Preserve an operator-managed OpenCode configuration. The bootstrap is only
  # for fresh persistent volumes and never overwrites an existing config.
  if [[ -e "$config_file" ]]; then
    return 0
  fi

  mkdir -p "$config_dir"
  umask 077
  cat > "$config_file" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "9router/high-model",
  "small_model": "9router/low-model",
  "provider": {
    "9router": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "9Router Self Hosted",
      "options": {
        "baseURL": "{env:NINEROUTER_BASE_URL}",
        "apiKey": "{env:NINEROUTER_API_KEY}"
      },
      "models": {
        "high-model": {
          "name": "9Router High Model"
        },
        "low-model": {
          "name": "9Router Low Model"
        },
        "free-model": {
          "name": "9Router Free Model"
        }
      }
    }
  }
}
JSON

  echo "OpenCode 9Router provider bootstrapped from runtime environment." >&2
}

bootstrap_opencode_9router

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
