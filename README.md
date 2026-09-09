# Orca HL — Headless Docker for Orca

Unofficial, versioned Docker distribution for the headless/remote-server mode of [StablyAI Orca](https://github.com/stablyai/orca), designed for Coolify and generic Docker Compose deployments.

The image follows Orca's official headless Linux guidance and is built from the exact upstream release AppImage. A version tag is published only after amd64 and arm64 smoke tests pass. `latest` tracks the newest stable upstream Orca release that passed this repository's tests.

## Image tags

```text
ghcr.io/konsultanedu-official/orca-hl:1.4.198
ghcr.io/konsultanedu-official/orca-hl:v1.4.198
ghcr.io/konsultanedu-official/orca-hl:1.4
ghcr.io/konsultanedu-official/orca-hl:1
ghcr.io/konsultanedu-official/orca-hl:latest
```

Use an exact version for production. Use `latest` for a canary/homeserver that should follow successfully tested upstream releases.

## Quick start with Coolify

Set these environment variables in Coolify:

```env
ORCA_TAG=latest
ORCA_PAIRING_ADDRESS=wss://orca.example.com
```

Then deploy `docker-compose.yml`. The Compose file uses `expose: 6768` instead of publishing port 6768 directly; route the domain to the Orca service through Coolify/Traefik.

For a pinned production deployment:

```env
ORCA_TAG=1.4.198
ORCA_PAIRING_ADDRESS=wss://orca.example.com
```

## Persistent data

The Compose file persists:

- Orca runtime/config: `/home/orca/.config/orca`
- Electron/Orca profile data: `/home/orca/.config/Orca`
- OpenCode config/data
- Orca projects and workspaces
- shared agent skills: `/home/orca/.agents`
- GitHub CLI config: `/home/orca/.config/gh`

The container runs as unprivileged UID `10001` (`orca`). If you replace named volumes with host bind mounts, make those directories writable by UID/GID `10001`.

## Orca CLI

The first packaged `orca serve` launch registers Orca's managed Linux CLI under:

```text
/home/orca/.local/bin/orca
/home/orca/.local/bin/orca-ide
```

Check it after startup:

```bash
docker compose exec orca orca status --json
docker compose exec orca orca terminal list --json
docker compose exec orca orca skills get orca-cli
```

## Skills

The persistent `/home/orca/.agents` volume is the shared/global Skills location. Install the Orca core skills once after the runtime is running:

```bash
docker compose exec orca orca skills install \
  --skill orca-cli \
  --skill orchestration \
  --skill computer-use
```

They survive container recreation because `/home/orca/.agents` is persistent.

`computer-use` controls native desktop apps and is inherently more limited in a headless container. Orca's built-in browser/automation is a separate feature and remains part of the remote-server runtime.

## Browser / Chromium

Orca launches Xvfb automatically when no `DISPLAY` is set. The image installs the dependency set required by the official Orca headless Linux guide and runs Orca as a non-root user so Chromium's sandbox can remain enabled.

The Compose deployment also sets:

```yaml
shm_size: "1gb"
```

because Chromium/Electron is less reliable with Docker's default 64 MiB `/dev/shm`.

## MCP

Node.js 22, npm/npx, Python 3, and `python3-venv` are available for common stdio MCP servers. Remote HTTP MCP endpoints need no additional runtime package. MCP configuration itself is managed inside Orca and persisted with the Orca config volumes.

## Git and GitHub CLI

Normal Git transport can use your deploy key/Git Stream workflow. `gh` is still included because Orca's native GitHub PR/checks/issues features depend on GitHub CLI/API authentication. If you do not use those features, you do not need to authenticate `gh`.

## OpenCode

OpenCode remains preinstalled for parity with the original deployment. It can be disabled when building locally:

```bash
docker build \
  --build-arg INSTALL_OPENCODE=false \
  ...
```

## Automated release synchronization

`.github/workflows/release.yml` runs every six hours and can also be started manually.

Flow:

```text
stablyai/orca latest stable release
             |
             v
resolve version + upstream SHA-256 digests
             |
             v
build/test linux/amd64 + linux/arm64
             |
      all tests pass?
          /      \
        no        yes
        |          |
      stop         v
             publish GHCR
                  |
                  +--> :<version>
                  +--> :v<version>
                  +--> :<major.minor>
                  +--> :<major>
                  +--> :latest
                  |
                  v
             update VERSION
             create GitHub release
```

`latest`, major, and minor moving tags are promoted only when the target is the current latest non-prerelease upstream release.

Manual historical builds publish only the version aliases and do not move `latest`.

## CI acceptance gate

The smoke test checks:

- required command/runtime dependencies
- Orca AppRun executable
- Node/npm/npx
- Git and GitHub CLI
- OpenCode when installed
- headless `orca serve` readiness JSON (`schemaVersion: 1`)
- managed bare `orca` CLI registration
- `orca status --json`
- terminal CLI surface
- bundled Orca skill guide availability

A candidate that fails on either amd64 or arm64 is not published.

## Local build

Resolve the current release metadata first:

```bash
bash ./scripts/release-meta.sh "$(cat VERSION)"
```

Then pass the returned version and checksums as Docker build arguments. GitHub Actions does this automatically.

## Source of truth

- Orca upstream: https://github.com/stablyai/orca
- Headless Linux guide: https://github.com/stablyai/orca/blob/main/docs/reference/headless-linux-server.md
- Orca releases: https://github.com/stablyai/orca/releases

This repository packages Orca; it does not fork or modify Orca's application source code.
