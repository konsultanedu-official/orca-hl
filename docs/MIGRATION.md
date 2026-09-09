# Legacy root-based state migration

This runbook migrates persistent state from an older Orca container that stores
state under `/root/...` into the non-root `orca-hl` layout under `/home/orca/...`.

The migration is intentionally container/orchestrator neutral. It discovers the
actual Docker named volumes from a source container and a target container, so it
does not depend on Coolify, aaPanel, Portainer, or Compose-generated volume names.

## Safety model

`scripts/migrate-legacy-state.sh` is dry-run by default.

It will not:

- stop/start/restart either container,
- delete the source container,
- delete source volumes,
- overwrite a non-empty target volume by default,
- copy bind mounts,
- copy an ephemeral directory that is not backed by a persistent source volume.

`--execute` requires both source and target containers to already be stopped.
Copied target state is normalized to UID/GID `10001:10001` for the `orca` user.

Before `--execute`, take a host/platform-native backup or snapshot of valuable
source state. The repository does not create or manage backups.

## Important shell conventions used in this runbook

Text such as `LEGACY_CONTAINER_NAME` or `NEW_CANARY_CONTAINER_NAME` is descriptive
placeholder text. Replace it with the actual value before running the command.

Do **not** type angle-bracket placeholders such as `<new-canary-container>` into a
shell command. In Bash, `<` and `>` are redirection operators and can cause syntax
errors before the migration script is even invoked.

Likewise, typing this on separate shell lines:

```bash
ORCA_TAG=1.4.198
ORCA_PAIRING_ADDRESS=wss://canary.your-domain.tld
```

does not edit `.env`, and unexported shell variables are not inherited by child
processes. For persistent deployment configuration, edit `.env`. For a one-shot
preflight override, put the variables inline in front of the command.

## 1. Audit the legacy container

```bash
DOCKER_USE_SUDO=1 \
bash scripts/audit-legacy-mounts.sh LEGACY_CONTAINER_NAME
```

The audit reports:

- Orca pairing/port hints without dumping the full environment,
- reverse-proxy routing hints without dumping unrelated labels,
- current mount sources/destinations,
- `/root`-based persistent destinations,
- size/ownership of candidate state when the source is running,
- the legacy-to-current path map.

Use the routing hints to replace the documentation placeholder in `.env`. Never
deploy with `wss://orca.example.com`.

## 2. Pin the first canary

For a migration canary, use the exact image version that already passed CI/release
acceptance rather than a moving tag:

```env
ORCA_IMAGE=ghcr.io/konsultanedu-official/orca-hl
ORCA_TAG=1.4.198
ORCA_PAIRING_ADDRESS=wss://canary.your-domain.tld
```

Edit the existing `.env` file rather than assigning unexported shell variables.
For example:

```bash
cp .env .env.before-canary
sed -i 's#^ORCA_IMAGE=.*#ORCA_IMAGE=ghcr.io/konsultanedu-official/orca-hl#' .env
sed -i 's#^ORCA_TAG=.*#ORCA_TAG=1.4.198#' .env
sed -i 's#^ORCA_PAIRING_ADDRESS=.*#ORCA_PAIRING_ADDRESS=wss://canary.your-domain.tld#' .env
```

Replace `wss://canary.your-domain.tld` with the real canary endpoint before
running preflight.

Alternatively, for a read-only one-shot preflight without modifying `.env`, pass
exported values inline. Preflight resolves the same effective Compose environment
that Docker Compose will use:

```bash
ORCA_TAG=1.4.198 \
ORCA_PAIRING_ADDRESS=wss://canary.your-domain.tld \
DOCKER_USE_SUDO=1 \
DEPLOYMENT_MODE=proxy \
DEPLOYMENT_TIER=canary \
bash scripts/preflight.sh
```

Then run preflight against the persisted `.env` before deployment:

```bash
DOCKER_USE_SUDO=1 \
DEPLOYMENT_MODE=proxy \
DEPLOYMENT_TIER=canary \
bash scripts/preflight.sh
```

## 3. Materialize a fresh target container and fresh volumes

The migration tool needs a target container so it can discover the actual target
volume names. The target must use the new `/home/orca/...` mount destinations from
this repository.

For Coolify, create a separate canary resource from this repository with fresh
persistent volumes. Do not reuse the legacy resource's old root-based volumes.

For plain Compose, a stopped target can be materialized without starting Orca:

```bash
DOCKER_USE_SUDO=1 sudo -v
sudo docker compose --env-file .env -f docker-compose.yml create orca
sudo docker compose --env-file .env -f docker-compose.yml ps -a
```

The target must be a separate container from the legacy source.

## 4. Dry-run the migration

First obtain the real target name:

```bash
sudo docker ps -a --format '{{.Names}}\t{{.Image}}' | grep -i orca
```

Then run the migration using literal container names. Example shape:

```bash
SOURCE_CONTAINER='orca-old-123456'
TARGET_CONTAINER='orca-canary-654321'

DOCKER_USE_SUDO=1 \
bash scripts/migrate-legacy-state.sh \
  "$SOURCE_CONTAINER" \
  "$TARGET_CONTAINER"
```

The source may still be running for the dry-run because no data is copied.
Expected result ends with:

```text
MIGRATION_DRY_RUN_PASS
```

Review every `COPY` and `SKIP` line.

A `SKIP ... (no persistent source mount)` means that path exists only in the old
container filesystem or does not exist at all. It will not be silently copied.
For example, if legacy `~/.codex` or `~/.claude` was not mounted, authenticate
those agents again in the new runtime rather than trying to preserve ephemeral
credentials.

## 5. Backup and quiesce both sides

Before execution:

1. Create an external backup/snapshot of valuable legacy state.
2. Stop the legacy Orca container/resource.
3. Stop the new target container/resource.
4. Confirm both are stopped.

The migration script refuses `--execute` while either container is running. It
does not stop them for you.

## 6. Execute

```bash
DOCKER_USE_SUDO=1 \
bash scripts/migrate-legacy-state.sh --execute \
  "$SOURCE_CONTAINER" \
  "$TARGET_CONTAINER"
```

The tool:

1. resolves each mounted source and target Docker named volume,
2. refuses bind mounts,
3. refuses identical source/target volume IDs,
4. refuses a non-empty target by default,
5. copies source data through a temporary helper container,
6. changes only the copied target state ownership to `10001:10001`,
7. verifies source/target entry counts,
8. leaves all source volumes intact.

Expected result:

```text
MIGRATION_EXECUTE_PASS
```

Do not set `ALLOW_NONEMPTY_TARGET=1` for the first migration. A fresh empty target
is safer than merging two state histories.

## 7. Start only the canary and run acceptance

Start the new target through its owning orchestrator, then run:

```bash
DOCKER_USE_SUDO=1 \
DEPLOYMENT_MODE=proxy \
EXPECTED_VERSION=1.4.198 \
bash scripts/runtime-acceptance.sh
```

The acceptance gate verifies non-root UID/HOME, health, persisted directories,
agent CLI availability, Orca CLI/status/terminal surfaces, absence of legacy
`/root` mounts, and known fatal log regressions.

## 8. Re-authenticate non-persistent identities

If legacy Codex/Claude/GitHub account state was not backed by a mounted volume, do
not copy credentials out of the old container filesystem as part of this automated
migration. Authenticate again into the new persistent volumes:

```bash
docker compose exec orca gh auth login
docker compose exec orca orca account add
docker compose exec orca orca account add --agent codex
```

Use your orchestrator's normal secret/account flow when applicable.

## 9. Functional QA and persistence test

After runtime acceptance passes:

- open an existing migrated project,
- inspect migrated worktrees,
- run a disposable terminal,
- launch Codex/Claude/OpenCode as applicable,
- exercise the built-in browser,
- verify GitHub integration after authentication,
- verify required MCP servers,
- perform one controlled canary container recreation and confirm state survives.

Only after these checks should production migration be considered.

## 10. Rollback

The migration never deletes source state. If the canary fails:

- stop the new canary,
- keep its target volumes for diagnosis,
- restart the legacy deployment if needed,
- do not point the legacy root-based volumes at the new UID 10001 image.

Rollback should restore the previous deployment path; it should not destroy either
copy of persistent state.
