#!/usr/bin/env bash

# Shared Docker CLI access resolver for operational scripts.
#
# DOCKER_USE_SUDO=auto (default)
#   1. use direct Docker access when available;
#   2. otherwise use cached/non-interactive sudo when available;
#   3. otherwise fail with an actionable message.
#
# DOCKER_USE_SUDO=0
#   Require direct Docker access.
#
# DOCKER_USE_SUDO=1
#   Require sudo Docker access. This mode may prompt for the sudo password when
#   invoked from an interactive terminal.
#
# On success the global array DOCKER_CMD is populated and can be used as:
#   "${DOCKER_CMD[@]}" ps
#   "${DOCKER_CMD[@]}" compose version

orca_resolve_docker_access() {
  local mode="${DOCKER_USE_SUDO:-auto}"

  DOCKER_CMD=()
  ORCA_DOCKER_ACCESS_MODE=""
  ORCA_DOCKER_ACCESS_ERROR=""

  command -v docker >/dev/null 2>&1 || {
    ORCA_DOCKER_ACCESS_ERROR="docker CLI is not installed"
    return 1
  }

  case "$mode" in
    auto)
      if docker info >/dev/null 2>&1; then
        DOCKER_CMD=(docker)
        ORCA_DOCKER_ACCESS_MODE="direct"
        return 0
      fi

      if command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
        DOCKER_CMD=(sudo -n docker)
        ORCA_DOCKER_ACCESS_MODE="sudo-cached"
        return 0
      fi

      ORCA_DOCKER_ACCESS_ERROR="Docker daemon is running but is not accessible by the current user. Re-run with DOCKER_USE_SUDO=1 (interactive sudo), or configure an intentional Docker access policy for this account."
      return 1
      ;;

    0)
      if docker info >/dev/null 2>&1; then
        DOCKER_CMD=(docker)
        ORCA_DOCKER_ACCESS_MODE="direct"
        return 0
      fi

      ORCA_DOCKER_ACCESS_ERROR="direct Docker access is unavailable while DOCKER_USE_SUDO=0"
      return 1
      ;;

    1)
      command -v sudo >/dev/null 2>&1 || {
        ORCA_DOCKER_ACCESS_ERROR="sudo is not installed but DOCKER_USE_SUDO=1 was requested"
        return 1
      }

      # Intentionally allow sudo to prompt here. Explicit mode=1 means the user
      # asked the script to use interactive sudo when necessary.
      if sudo docker info >/dev/null; then
        DOCKER_CMD=(sudo docker)
        ORCA_DOCKER_ACCESS_MODE="sudo"
        return 0
      fi

      ORCA_DOCKER_ACCESS_ERROR="sudo Docker access failed"
      return 1
      ;;

    *)
      ORCA_DOCKER_ACCESS_ERROR="DOCKER_USE_SUDO must be auto, 0, or 1"
      return 1
      ;;
  esac
}
