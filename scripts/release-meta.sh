#!/usr/bin/env bash
set -Eeuo pipefail

requested="${1:-latest}"
requested="${requested#v}"

if [[ "$requested" == "latest" ]]; then
  api_url="https://api.github.com/repos/stablyai/orca/releases/latest"
else
  api_url="https://api.github.com/repos/stablyai/orca/releases/tags/v${requested}"
fi

curl_headers=(
  -H 'Accept: application/vnd.github+json'
  -H 'X-GitHub-Api-Version: 2022-11-28'
  -H 'User-Agent: konsultanedu-official/orca-hl-release-sync'
)

# Anonymous GitHub REST requests share a much smaller rate-limit bucket and can
# intermittently fail with HTTP 403 on hosted runners. Use the workflow token
# when available, while keeping the script usable locally without credentials.
github_token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [[ -n "$github_token" ]]; then
  curl_headers+=( -H "Authorization: Bearer $github_token" )
fi

json="$(curl -fsSL --retry 5 --retry-delay 2 \
  "${curl_headers[@]}" \
  "$api_url")"

tag="$(jq -r '.tag_name' <<<"$json")"
version="${tag#v}"
draft="$(jq -r '.draft' <<<"$json")"
prerelease="$(jq -r '.prerelease' <<<"$json")"

[[ -n "$tag" && "$tag" != "null" ]] || { echo "Missing release tag from GitHub API response" >&2; exit 1; }
[[ "$draft" == "false" ]] || { echo "Refusing draft release: $tag" >&2; exit 1; }

amd64_digest="$(jq -r '.assets[] | select(.name == "orca-linux.AppImage") | .digest // empty' <<<"$json" | sed 's/^sha256://')"
arm64_digest="$(jq -r '.assets[] | select(.name == "orca-linux-arm64.AppImage") | .digest // empty' <<<"$json" | sed 's/^sha256://')"

[[ -n "$amd64_digest" ]] || { echo "Missing amd64 AppImage digest for $tag" >&2; exit 1; }
[[ -n "$arm64_digest" ]] || { echo "Missing arm64 AppImage digest for $tag" >&2; exit 1; }

printf 'version=%s\n' "$version"
printf 'tag=%s\n' "$tag"
printf 'prerelease=%s\n' "$prerelease"
printf 'amd64_sha256=%s\n' "$amd64_digest"
printf 'arm64_sha256=%s\n' "$arm64_digest"
