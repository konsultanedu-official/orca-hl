# syntax=docker/dockerfile:1.7

FROM node:22-bookworm-slim AS node-runtime

FROM ubuntu:22.04

ARG ORCA_VERSION
ARG ORCA_SHA256_AMD64=""
ARG ORCA_SHA256_ARM64=""
ARG TARGETARCH
ARG BUILD_DATE=""
ARG VCS_REF=""
ARG INSTALL_OPENCODE="true"

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/orca \
    LIBGL_ALWAYS_SOFTWARE=1 \
    ORCA_IMAGE_VERSION="${ORCA_VERSION}" \
    PATH=/home/orca/.opencode/bin:/home/orca/.local/bin:/opt/orca/squashfs-root/resources/bin:/usr/local/bin:/usr/bin:/bin

LABEL org.opencontainers.image.title="Orca Headless Docker" \
      org.opencontainers.image.description="Unofficial headless Docker distribution for StablyAI Orca" \
      org.opencontainers.image.source="https://github.com/konsultanedu-official/orca-hl" \
      org.opencontainers.image.version="${ORCA_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      io.orca.upstream.repository="https://github.com/stablyai/orca" \
      io.orca.upstream.version="v${ORCA_VERSION}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      file \
      git \
      jq \
      openssh-client \
      procps \
      python3 \
      python3-venv \
      tini \
      util-linux \
      wget \
      xauth \
      xvfb \
      zlib1g-dev \
      libgtk-3-0 \
      libnss3 \
      libatk1.0-0 \
      libatk-bridge2.0-0 \
      libgbm1 \
      libasound2 \
      libxtst6 \
      libcups2 \
      libdrm2 \
      libxkbcommon0 \
      libpango-1.0-0 \
      libcairo2 \
      libatspi2.0-0 \
      libxcomposite1 \
      libxdamage1 \
      libxfixes3 \
      libxrandr2 \
      libxrender1 \
      libx11-xcb1 \
      libxcb-dri3-0 \
      libxss1 \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22 + npm/npx for agent tooling, Skills and Node-based MCP servers.
COPY --from=node-runtime /usr/local/bin/node /usr/local/bin/node
COPY --from=node-runtime /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && node --version \
    && npm --version

# GitHub CLI is kept because Orca's native GitHub PR/checks/issues features use gh.
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/* \
    && gh --version

RUN test -n "${ORCA_VERSION}" \
    && case "${TARGETARCH}" in \
      amd64) ORCA_ASSET="orca-linux.AppImage"; ORCA_SHA256="${ORCA_SHA256_AMD64}" ;; \
      arm64) ORCA_ASSET="orca-linux-arm64.AppImage"; ORCA_SHA256="${ORCA_SHA256_ARM64}" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && mkdir -p /opt/orca \
    && curl -fL --retry 5 --retry-delay 2 \
      "https://github.com/stablyai/orca/releases/download/v${ORCA_VERSION}/${ORCA_ASSET}" \
      -o /opt/orca/orca.AppImage \
    && if [ -n "${ORCA_SHA256}" ]; then \
         printf '%s  %s\n' "${ORCA_SHA256}" /opt/orca/orca.AppImage | sha256sum -c -; \
       else \
         echo "WARNING: ORCA_SHA256 for ${TARGETARCH} was not supplied; skipping checksum verification" >&2; \
       fi \
    && chmod 0755 /opt/orca/orca.AppImage \
    && cd /opt/orca \
    && ./orca.AppImage --appimage-extract \
    && chmod -R a+rX /opt/orca/squashfs-root \
    && rm /opt/orca/orca.AppImage

RUN useradd --create-home --shell /bin/bash --uid 10001 orca \
    && mkdir -p \
      /projects \
      /home/orca/orca/workspaces \
      /home/orca/.config/orca \
      /home/orca/.config/Orca \
      /home/orca/.config/opencode \
      /home/orca/.config/gh \
      /home/orca/.local/share/opencode \
      /home/orca/.agents \
    && chown -R orca:orca /projects /home/orca

USER orca

# Keep OpenCode as the preinstalled default agent for parity with the current deployment.
# It can be disabled at build time with --build-arg INSTALL_OPENCODE=false.
RUN if [ "${INSTALL_OPENCODE}" = "true" ]; then \
      curl -fsSL https://opencode.ai/install -o /tmp/install-opencode.sh \
      && SHELL=/bin/bash bash /tmp/install-opencode.sh --no-modify-path \
      && test -x /home/orca/.opencode/bin/opencode \
      && /home/orca/.opencode/bin/opencode --version \
      && rm /tmp/install-opencode.sh; \
    fi

USER root
COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --chmod=0755 scripts/healthcheck.sh /usr/local/bin/healthcheck.sh
COPY --chmod=0755 scripts/smoke-test.sh /usr/local/bin/smoke-test.sh
USER orca

WORKDIR /projects
EXPOSE 6768

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["serve"]
