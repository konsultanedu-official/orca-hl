FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/root/.opencode/bin:/root/.local/bin:/app/squashfs-root/resources/bin:${PATH}"

RUN apt-get update && apt-get install -y \
    xvfb \
    libgtk-3-0 \
    libnss3 \
    libasound2 \
    libgbm1 \
    libxss1 \
    ca-certificates \
    curl \
    git \
    openssh-client \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Orca 1.4.197
RUN curl -fsSL -o orca-linux.AppImage \
    https://github.com/stablyai/orca/releases/download/v1.4.197/orca-linux.AppImage \
    && chmod +x orca-linux.AppImage \
    && ./orca-linux.AppImage --appimage-extract \
    && rm orca-linux.AppImage

# OpenCode
RUN curl -fsSL https://opencode.ai/install \
    -o /tmp/install-opencode.sh \
    && SHELL=/bin/bash bash /tmp/install-opencode.sh --no-modify-path \
    && test -x /root/.opencode/bin/opencode \
    && /root/.opencode/bin/opencode --version \
    && rm /tmp/install-opencode.sh

# Node.js 22
COPY --from=node:22-bookworm-slim /usr/local/bin/node /usr/local/bin/node
COPY --from=node:22-bookworm-slim /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm

RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && node --version \
    && npm --version \
    && node -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major !== 22 || minor < 12) process.exit(1);'

EXPOSE 6768

CMD ["/app/squashfs-root/AppRun", "serve", "--port", "6768", "--no-sandbox"]
