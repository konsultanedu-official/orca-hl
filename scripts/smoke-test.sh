#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  echo "SMOKE_TEST_FAIL: $*" >&2
  exit 1
}

for cmd in git node npm npx gh Xvfb jq python3; do
  command -v "$cmd" >/dev/null 2>&1 || fail "missing command: $cmd"
done

app="/opt/orca/squashfs-root/AppRun"
[[ -x "$app" ]] || fail "missing Orca AppRun"

node --version
npm --version
git --version
gh --version

if command -v opencode >/dev/null 2>&1; then
  opencode --version
fi

log="$(mktemp)"
pid=""
cleanup() {
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -f "$log"
}
trap cleanup EXIT

"$app" serve --port 6768 --pairing-address 127.0.0.1 --json >"$log" 2>&1 &
pid=$!

ready=0
for _ in $(seq 1 180); do
  if grep -q '"type":"orca_server_ready"' "$log"; then
    ready=1
    break
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    cat "$log" >&2
    fail "Orca server exited before readiness"
  fi
  sleep 1
done

if [[ "$ready" != "1" ]]; then
  cat "$log" >&2
  fail "Orca readiness contract was not observed"
fi

ready_line="$(grep '"type":"orca_server_ready"' "$log" | tail -1)"
printf '%s\n' "$ready_line" | jq -e '.type == "orca_server_ready" and .schemaVersion == 1' >/dev/null \
  || fail "invalid readiness JSON contract"

cli="${HOME}/.local/bin/orca"
for _ in $(seq 1 30); do
  [[ -x "$cli" ]] && break
  sleep 1
done
[[ -x "$cli" ]] || fail "managed bare orca CLI was not registered"

"$cli" status --json >/dev/null || fail "orca status failed"
"$cli" terminal list --json >/dev/null || fail "orca terminal list failed"
"$cli" skills get orca-cli >/dev/null || fail "orca skills guide unavailable"

printf 'SMOKE_TEST_PASS\n'
