# Canary Deployment Runbook

This runbook validates a published `orca-hl` image before it is promoted into a production host. It is intentionally orchestrator-neutral and works with Coolify/reverse-proxy deployments, aaPanel/plain Docker, or another Docker Compose compatible platform.

## Safety boundary

The repository scripts used here are read-only unless a command is explicitly shown as a deployment command.

- `scripts/preflight.sh` does not pull/start/stop/mutate anything.
- `scripts/audit-legacy-mounts.sh` does not start/stop/copy/chown/delete anything.
- `scripts/runtime-acceptance.sh` only inspects a running deployment.
- Authentication, skill installation, data migration, and deployment remain explicit operator actions.

Do not attach legacy root-owned state directly to the new UID `10001` runtime.

## 1. Choose the image

For the first canary, prefer the exact released version so the test is reproducible:

```env
ORCA_IMAGE=ghcr.io/konsultanedu-official/orca-hl
ORCA_TAG=1.4.198
ORCA_PAIRING_ADDRESS=wss://orca.example.com
```

After the exact version passes and you intentionally want the canary to track promoted releases, change only the canary to:

```env
ORCA_TAG=latest
```

Production should remain pinned to an exact tested version.

## 2. Audit any legacy deployment first

If an older Orca container exists, inspect it before touching its volumes:

```bash
bash scripts/audit-legacy-mounts.sh <old-container-name>
```

Record:

- source and destination of every mount,
- whether any destination is under `/root`,
- UID/GID/mode of state directories,
- approximate size of each state surface,
- which data actually needs to be migrated.

Do not migrate by assumption. An old container can contain only a subset of the paths listed by the audit.

## 3. Run preflight

Create the runtime env file:

```bash
cp .env.example .env
```

### Coolify / Traefik / reverse-proxy mode

```bash
DEPLOYMENT_MODE=proxy \
DEPLOYMENT_TIER=canary \
bash scripts/preflight.sh
```

### aaPanel / plain Docker host-port mode

```bash
DEPLOYMENT_MODE=host \
DEPLOYMENT_TIER=canary \
bash scripts/preflight.sh
```

Preflight validates:

- Docker and Compose availability,
- Compose interpolation/model,
- deployment tier/tag policy,
- pairing address presence,
- host bind safety warning,
- registry manifest reachability,
- advertised amd64/arm64 manifest platforms when visible to Buildx.

A preflight failure must be resolved before deployment.

## 4. Start the canary

### Reverse-proxy orchestrator

Use `docker-compose.yml` as the service model. Route the platform proxy to service `orca`, internal port `6768`.

For a plain Compose test using the base model:

```bash
docker compose --env-file .env -f docker-compose.yml pull
docker compose --env-file .env -f docker-compose.yml up -d
```

### Host-port deployment

```bash
docker compose --env-file .env \
  -f docker-compose.yml \
  -f docker-compose.host.yml \
  pull

docker compose --env-file .env \
  -f docker-compose.yml \
  -f docker-compose.host.yml \
  up -d
```

Default host publishing is `127.0.0.1:6768:6768`.

## 5. Run runtime acceptance

For Orca `1.4.198`:

### Reverse-proxy mode

```bash
DEPLOYMENT_MODE=proxy \
EXPECTED_VERSION=1.4.198 \
bash scripts/runtime-acceptance.sh
```

### Host mode

```bash
DEPLOYMENT_MODE=host \
EXPECTED_VERSION=1.4.198 \
bash scripts/runtime-acceptance.sh
```

The acceptance gate fails on conditions such as:

- container not running/healthy,
- runtime UID is not `10001`,
- HOME is not `/home/orca`,
- wrong image version,
- missing Codex/Claude/OpenCode/Git/Node/Python/gh tooling,
- unavailable `codex app-server`,
- non-writable persistent state,
- a mounted destination still under `/root`,
- Orca CLI/status/terminal/skill guide failure,
- known fatal log patterns such as `spawn codex ENOENT`, `Exec format error`, `Permission denied`, or `EACCES`.

GitHub authentication is a warning by default because credentials are runtime state. To require it after authentication is configured:

```bash
REQUIRE_GH_AUTH=1 \
DEPLOYMENT_MODE=proxy \
EXPECTED_VERSION=1.4.198 \
bash scripts/runtime-acceptance.sh
```

## 6. Configure identities after the base runtime passes

Credentials are not part of the image.

Examples:

```bash
docker compose exec orca gh auth login
docker compose exec orca orca account add
docker compose exec orca orca account add --agent codex
```

Then rerun runtime acceptance with `REQUIRE_GH_AUTH=1` if GitHub integration is part of the canary acceptance scope.

## 7. Install shared Orca skills explicitly

After the runtime is stable:

```bash
docker compose exec orca orca skills install \
  --skill orca-cli \
  --skill orchestration \
  --skill computer-use
```

The shared skill directory is persisted at `/home/orca/.agents`.

## 8. Functional QA checklist

Run these as a separate functional layer after the automated runtime gate:

1. Connect the intended Orca client through the configured pairing address.
2. Open an existing project/repository.
3. Create a disposable worktree.
4. Start a disposable terminal and verify read/write output.
5. Launch Codex and confirm no `ENOENT`/trust-startup regression.
6. Launch Claude Code and OpenCode where relevant.
7. Open the built-in browser against a test/dev URL.
8. Check browser snapshot, console, and network surfaces.
9. Verify GitHub issue/PR access only after `gh` authentication is configured.
10. Verify required MCP servers independently; MCP provider credentials remain runtime secrets.

Do not use production repositories, destructive commands, or production deployment credentials for the first canary functional test.

## 9. Promotion rule

The canary is eligible for production only when:

- preflight passes,
- runtime acceptance passes,
- functional QA passes,
- no legacy volume/ownership ambiguity remains,
- required identities are persistent across a controlled container recreation,
- rollback has been rehearsed or is mechanically clear.

Pin production to the exact canary-tested version, for example:

```env
ORCA_TAG=1.4.198
```

Do not promote production merely because `latest` moved.

## 10. Rollback principle

Rollback should change the image version/configuration, not delete persistent state.

Before any migration that changes existing data, create a host/platform-native backup or snapshot outside this repository. This project deliberately does not automate destructive migration or rollback of user state.
