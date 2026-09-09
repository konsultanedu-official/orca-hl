# Orca HL — Universal Headless Docker for Orca

Unofficial, versioned OCI/Docker distribution for the headless/remote-server mode of [StablyAI Orca](https://github.com/stablyai/orca).

The image is intentionally orchestrator-neutral: the same image can run with Coolify, aaPanel, plain Docker Compose, Portainer, Docker Swarm-compatible tooling, or another OCI-capable platform. Registry location is also independent; GHCR is the default, but the image can be mirrored to Docker Hub or another OCI registry without changing the runtime design.

The wrapper follows Orca's official headless Linux guidance and builds from an exact upstream release AppImage. A version is published only after native amd64 and arm64 smoke tests pass. `latest` means the newest stable upstream Orca release that passed this repository's acceptance gate.

## Included runtime

The default image is batteries-included for Orca's headless development workflow:

- Orca headless runtime
- Xvfb + Electron/Chromium runtime dependencies
- Node.js 22, npm and npx
- Python 3 + venv
- Git + OpenSSH client
- GitHub CLI (`gh`)
- Codex CLI (pinned)
- Claude Code CLI (pinned stable version)
- OpenCode CLI (pinned)
- common prerequisites for Node/Python MCP servers

Agent binaries are part of the immutable image; user identities, credentials and tokens are not.

## Image tags

```text
ghcr.io/konsultanedu-official/orca-hl:1.4.198
ghcr.io/konsultanedu-official/orca-hl:v1.4.198
ghcr.io/konsultanedu-official/orca-hl:1.4
ghcr.io/konsultanedu-official/orca-hl:1
ghcr.io/konsultanedu-official/orca-hl:latest
```

Use an exact version for production. Use `latest` for a canary/homeserver that should follow successfully tested upstream releases.

## Configuration

Copy the example and set the advertised endpoint:

```bash
cp .env.example .env
```

Minimum values:

```env
ORCA_TAG=latest
ORCA_PAIRING_ADDRESS=wss://orca.example.com
```

`--pairing-address` is the endpoint advertised to clients; it is not the listener bind address.

## Coolify / reverse-proxy orchestrators

Use the base Compose file:

```bash
docker compose -f docker-compose.yml config
```

`docker-compose.yml` exposes container port `6768` internally without publishing a host port. Point Coolify/Traefik or your orchestrator's reverse proxy at service `orca`, port `6768`.

## aaPanel / plain Docker / Portainer host-port deployment

Use the host networking override:

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.host.yml \
  up -d
```

Defaults:

```env
ORCA_BIND_ADDRESS=127.0.0.1
ORCA_HOST_PORT=6768
```

This publishes `127.0.0.1:6768` for a host-level Nginx/aaPanel reverse proxy without exposing Orca directly to the public network. Change the bind address only when the deployment design requires it.

If an aaPanel/Portainer UI accepts only one Compose document, merge/render the model first or add the same `ports` entry to the service in that UI. The Docker image itself is unchanged.

## Other registries / Docker Hub

The deployment does not depend on GHCR. Point `ORCA_IMAGE` at a mirror of the same OCI image:

```env
ORCA_IMAGE=docker.io/example/orca-hl
ORCA_TAG=1.4.198
```

The registry changes where the image is pulled from, not how Orca runs.

## Persistent data

The base Compose persists these state surfaces independently:

- Orca runtime/config: `/home/orca/.config/orca`
- Electron/browser profile: `/home/orca/.config/Orca`
- OpenCode config/data
- Codex account/config: `/home/orca/.codex`
- Claude account/config: `/home/orca/.claude`
- projects: `/projects`
- Orca worktrees: `/home/orca/orca/workspaces`
- shared agent skills: `/home/orca/.agents`
- GitHub CLI config: `/home/orca/.config/gh`

The container runs as unprivileged UID `10001` (`orca`). If named volumes are replaced with bind mounts, those directories must be writable by UID/GID `10001`.

### Migration warning from older root-based images

Older deployments used paths under `/root`. Do not blindly attach an old root-owned volume to a new `/home/orca/...` mount. Audit/copy the data and ownership first; otherwise the non-root runtime can lose access even though the container itself starts correctly.

## Agent authentication

No provider credentials are baked into the image.

For Orca-managed headless accounts, run on the machine/container that owns the runtime:

```bash
# Claude Code account (default agent for account add)
docker compose exec orca orca account add

# Codex account
docker compose exec orca orca account add --agent codex
```

The account state survives recreation through the dedicated Claude/Codex volumes.

For GitHub CLI features:

```bash
docker compose exec orca gh auth login
```

`/home/orca/.config/gh` is persistent. For unattended environments you may instead inject provider-supported environment secrets from the orchestrator. Do not commit secrets to `.env`, Compose, Dockerfile, or the repository.

Until `gh` is authenticated, Orca GitHub issue/PR features can legitimately report the standard `gh auth login` error; installing the binary alone cannot authenticate a user.

## Why Codex is bundled

Orca launches the `codex` binary directly and uses Codex's `app-server` integration for deeper account/trust flows. The image therefore validates both:

```bash
codex --version
codex app-server --help
```

This specifically prevents a previously observed `spawn codex ENOENT` class of runtime failure from reaching a published image.

Claude Code and OpenCode are also verified as executable CLIs on both supported architectures.

## Orca CLI

The first packaged `orca serve` launch registers Orca's managed Linux CLI under the service user's home. Verify after startup:

```bash
docker compose exec orca orca status --json
docker compose exec orca orca terminal list --json
docker compose exec orca orca skills get orca-cli
```

## Skills

`/home/orca/.agents` is the persistent shared/global skills location. Install the Orca core skills after the runtime is running:

```bash
docker compose exec orca orca skills install \
  --skill orca-cli \
  --skill orchestration \
  --skill computer-use
```

They survive container recreation. `computer-use` controls native desktop apps and is inherently more limited in a headless container; Orca's built-in browser automation is a separate remote-runtime capability.

## Browser / Chromium

Orca starts Xvfb automatically when no usable `DISPLAY` exists. The image installs the dependency set required by the official headless Linux guide and runs Orca as a non-root user so Chromium sandboxing can remain enabled.

The Compose model also uses:

```yaml
shm_size: "1gb"
```

because Chromium/Electron is less reliable with Docker's default 64 MiB `/dev/shm`.

## MCP

Node.js, npm/npx, Python 3 and `python3-venv` are available for common stdio MCP servers. Remote HTTP MCP endpoints need no additional runtime package. MCP configuration consumed by Orca is persisted with Orca state.

A future external `orca-mcp` control-plane adapter should remain separate from this runtime image. The wrapper should expose Orca capabilities through Orca's agent-facing CLI rather than modifying Orca's internal protocol. The first control-plane milestone should be read-only/audit before write/execute tools are enabled.

## Automated release synchronization

`.github/workflows/release.yml` runs every six hours and can also be started manually.

```text
stablyai/orca latest stable release
             |
             v
resolve version + upstream SHA-256 digests
             |
             v
native build/test amd64 + arm64
             |
      all tests pass?
          /      \
        no        yes
        |          |
      stop         v
        exact tested per-arch images
                  |
                  v
           multi-arch manifest
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

`latest`, major and minor moving tags are promoted only when the target is the current latest non-prerelease upstream release. Manual historical builds do not move `latest`.

## CI acceptance gate

Both native architectures must pass:

- Compose model validation (base + host override)
- required headless runtime dependencies
- Orca AppRun executable
- Node/npm/npx, Git, GitHub CLI and Python
- Codex CLI + `codex app-server` capability
- Claude Code CLI
- OpenCode CLI
- writable persistent-state directories for Orca/agents
- headless `orca serve` readiness JSON (`schemaVersion: 1`)
- managed bare Orca CLI registration
- `orca status --json`
- terminal CLI surface
- bundled Orca skill guide availability

A candidate that fails on either amd64 or arm64 is not published.

## Source of truth

- Orca upstream: https://github.com/stablyai/orca
- Headless Linux guide: https://github.com/stablyai/orca/blob/main/docs/reference/headless-linux-server.md
- Orca releases: https://github.com/stablyai/orca/releases

This repository packages Orca; it does not modify Orca's application source code.
