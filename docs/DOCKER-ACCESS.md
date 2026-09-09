# Docker access modes

The Orca HL operational scripts support hosts where the Docker daemon is reachable only through `sudo`.

This is common on Ubuntu servers where the login user is not a member of the `docker` group. That is not a broken Docker installation: `sudo docker ps` can work while plain `docker ps` returns a permission error.

## Supported modes

All host-side operational scripts accept:

```text
DOCKER_USE_SUDO=auto|0|1
```

### `auto` (default)

1. Try direct Docker access.
2. If direct access fails, try cached/non-interactive sudo (`sudo -n docker ...`).
3. If neither works, stop with an actionable error.

If you recently authenticated with sudo, the default mode can therefore work without another password prompt.

### `0`

Require direct Docker access. This is useful for CI or hosts intentionally configured for non-sudo Docker access.

### `1`

Require `sudo docker ...`. This may prompt for the user's sudo password in an interactive terminal.

Example for a Coolify/proxy canary:

```bash
DOCKER_USE_SUDO=1 \
DEPLOYMENT_MODE=proxy \
DEPLOYMENT_TIER=canary \
bash scripts/preflight.sh
```

Runtime acceptance uses the same mechanism:

```bash
DOCKER_USE_SUDO=1 \
DEPLOYMENT_MODE=proxy \
EXPECTED_VERSION=1.4.198 \
bash scripts/runtime-acceptance.sh
```

Legacy mount audit:

```bash
DOCKER_USE_SUDO=1 \
bash scripts/audit-legacy-mounts.sh <container-name-or-id>
```

## Security note

The scripts do **not** automatically add users to the `docker` group, change `/var/run/docker.sock` permissions, or run `chmod 666` on the Docker socket.

Docker daemon access is effectively root-equivalent on a normal Docker host. Choose the host's access policy deliberately. Using `sudo` is a valid deployment model and does not require weakening socket permissions.

The preflight, runtime acceptance, and legacy mount audit remain read-only with respect to application/container state; `DOCKER_USE_SUDO=1` only changes how those Docker CLI reads are authorized.
