#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  echo "MIGRATION_FAIL: $*" >&2
  exit 1
}

warn() {
  echo "MIGRATION_WARN: $*" >&2
}

info() {
  echo "MIGRATION_INFO: $*"
}

usage() {
  cat <<'EOF'
Usage:
  bash scripts/migrate-legacy-state.sh <source-container> <target-container>
  bash scripts/migrate-legacy-state.sh --execute <source-container> <target-container>

Default mode is DRY RUN. It only inspects container mounts and prints the planned
volume-to-volume migration.

Execution mode copies data only between Docker named volumes already attached to
the two containers. It never deletes the source volume/container and never starts,
stops, or restarts either container.

Safety requirements for --execute:
  - source and target containers must both be stopped;
  - source and target state must be Docker named volumes (not bind mounts);
  - target volume must be empty unless ALLOW_NONEMPTY_TARGET=1 is explicitly set;
  - copied target state is normalized to UID/GID 10001:10001.

Environment:
  DOCKER_USE_SUDO=auto|0|1
  ALLOW_NONEMPTY_TARGET=0|1      Default: 0
  MIGRATION_HELPER_IMAGE=alpine:3.20

The migration maps legacy /root-based Orca state into /home/orca-based state.
Only mounted/persistent source paths are copied. Ephemeral source directories that
exist only inside the old container filesystem are intentionally not migrated.
EOF
}

execute=0
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if [[ "${1:-}" == "--execute" ]]; then
  execute=1
  shift
fi

[[ $# -eq 2 ]] || {
  usage >&2
  exit 2
}

source_container="$1"
target_container="$2"
ALLOW_NONEMPTY_TARGET="${ALLOW_NONEMPTY_TARGET:-0}"
MIGRATION_HELPER_IMAGE="${MIGRATION_HELPER_IMAGE:-alpine:3.20}"

case "$ALLOW_NONEMPTY_TARGET" in
  0|1) ;;
  *) fail "ALLOW_NONEMPTY_TARGET must be 0 or 1" ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/docker-access.sh
source "$ROOT/scripts/lib/docker-access.sh"

orca_resolve_docker_access || fail "$ORCA_DOCKER_ACCESS_ERROR"
info "Docker access: $ORCA_DOCKER_ACCESS_MODE"

"${DOCKER_CMD[@]}" inspect "$source_container" >/dev/null 2>&1 || fail "source container not found: $source_container"
"${DOCKER_CMD[@]}" inspect "$target_container" >/dev/null 2>&1 || fail "target container not found: $target_container"

source_running="$("${DOCKER_CMD[@]}" inspect -f '{{.State.Running}}' "$source_container")"
target_running="$("${DOCKER_CMD[@]}" inspect -f '{{.State.Running}}' "$target_container")"
source_image="$("${DOCKER_CMD[@]}" inspect -f '{{.Config.Image}}' "$source_container")"
target_image="$("${DOCKER_CMD[@]}" inspect -f '{{.Config.Image}}' "$target_container")"

info "source: $source_container ($source_image), running=$source_running"
info "target: $target_container ($target_image), running=$target_running"

if [[ "$execute" == "1" ]]; then
  [[ "$source_running" == "false" ]] || fail "source container must be stopped before --execute"
  [[ "$target_running" == "false" ]] || fail "target container must be stopped before --execute"
fi

mount_info() {
  local container="$1"
  local destination="$2"
  "${DOCKER_CMD[@]}" inspect -f "{{range .Mounts}}{{if eq .Destination \"$destination\"}}{{printf \"%s\\t%s\\t%s\" .Type .Name .Source}}{{end}}{{end}}" "$container"
}

volume_nonempty() {
  local volume="$1"
  "${DOCKER_CMD[@]}" run --rm -v "$volume:/data:ro" "$MIGRATION_HELPER_IMAGE" \
    sh -ec 'test -n "$(ls -A /data 2>/dev/null)"'
}

entry_count() {
  local volume="$1"
  "${DOCKER_CMD[@]}" run --rm -v "$volume:/data:ro" "$MIGRATION_HELPER_IMAGE" \
    sh -ec 'find /data -mindepth 1 -xdev 2>/dev/null | wc -l'
}

volume_size() {
  local volume="$1"
  "${DOCKER_CMD[@]}" run --rm -v "$volume:/data:ro" "$MIGRATION_HELPER_IMAGE" \
    sh -ec "du -sh /data 2>/dev/null | awk '{print \\$1}'"
}

legacy_paths=(
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

target_paths=(
  /home/orca/.config/orca
  /home/orca/.config/Orca
  /home/orca/.config/opencode
  /home/orca/.local/share/opencode
  /home/orca/.codex
  /home/orca/.claude
  /home/orca/.agents
  /home/orca/.config/gh
  /home/orca/orca/workspaces
  /projects
)

planned=0
skipped=0

declare -a plan_src_volumes=()
declare -a plan_dst_volumes=()
declare -a plan_labels=()

echo
echo '=== Migration plan ==='
for i in "${!legacy_paths[@]}"; do
  src_path="${legacy_paths[$i]}"
  dst_path="${target_paths[$i]}"
  src_info="$(mount_info "$source_container" "$src_path")"
  dst_info="$(mount_info "$target_container" "$dst_path")"

  if [[ -z "$src_info" ]]; then
    printf 'SKIP\t%s -> %s\t(no persistent source mount)\n' "$src_path" "$dst_path"
    skipped=$((skipped + 1))
    continue
  fi

  [[ -n "$dst_info" ]] || fail "target has no mount for $dst_path"

  IFS=$'\t' read -r src_type src_name src_source <<<"$src_info"
  IFS=$'\t' read -r dst_type dst_name dst_source <<<"$dst_info"

  [[ "$src_type" == "volume" ]] || fail "source $src_path uses unsupported mount type: $src_type"
  [[ "$dst_type" == "volume" ]] || fail "target $dst_path uses unsupported mount type: $dst_type"
  [[ -n "$src_name" && -n "$dst_name" ]] || fail "could not resolve named volumes for $src_path -> $dst_path"
  [[ "$src_name" != "$dst_name" ]] || fail "source and target resolve to the same volume for $src_path"

  size="$(volume_size "$src_name" || true)"
  count="$(entry_count "$src_name" || true)"
  printf 'COPY\t%s [%s] -> %s [%s]\tsize=%s entries=%s\n' \
    "$src_path" "$src_name" "$dst_path" "$dst_name" "${size:-unknown}" "${count:-unknown}"

  if volume_nonempty "$dst_name"; then
    if [[ "$ALLOW_NONEMPTY_TARGET" == "1" ]]; then
      warn "target volume is non-empty and overwrite/merge was explicitly allowed: $dst_name"
    else
      fail "target volume is not empty: $dst_name (refusing merge; use a fresh target volume)"
    fi
  fi

  plan_src_volumes+=("$src_name")
  plan_dst_volumes+=("$dst_name")
  plan_labels+=("$src_path -> $dst_path")
  planned=$((planned + 1))
done

info "planned persistent surfaces: $planned"
info "skipped non-persistent/missing source surfaces: $skipped"

if [[ "$execute" != "1" ]]; then
  echo
  info "DRY RUN ONLY: no data was copied and no ownership was changed"
  info "before --execute: back up source state, then stop BOTH source and target containers"
  printf 'MIGRATION_DRY_RUN_PASS\n'
  exit 0
fi

(( planned > 0 )) || fail "nothing to migrate"

echo
echo '=== Executing migration ==='
for i in "${!plan_src_volumes[@]}"; do
  src_volume="${plan_src_volumes[$i]}"
  dst_volume="${plan_dst_volumes[$i]}"
  label="${plan_labels[$i]}"
  before_count="$(entry_count "$src_volume")"

  info "copying $label"
  "${DOCKER_CMD[@]}" run --rm \
    -v "$src_volume:/src:ro" \
    -v "$dst_volume:/dst" \
    "$MIGRATION_HELPER_IMAGE" \
    sh -ec 'cp -a /src/. /dst/ && chown -R 10001:10001 /dst'

  after_count="$(entry_count "$dst_volume")"
  [[ "$before_count" == "$after_count" ]] || fail "entry-count verification failed for $label: source=$before_count target=$after_count"
  info "verified $label entries=$after_count owner=10001:10001"
done

echo
info "source volumes were preserved; no source data was deleted"
info "target state now belongs to UID/GID 10001:10001"
printf 'MIGRATION_EXECUTE_PASS\n'
