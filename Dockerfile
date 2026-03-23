# ============================================================================
# Runtime image layout:
#   /openclaw          – OpenClaw built from source (full repo + dist)
#   /missioncontrol    – Mission Control: compiled CLI binary + TS source
#   /app               – This project's wrapper server (server.js)
#   /data              – Northflank persistent volume (mounted at runtime)
#
# Two build stages produce artifacts that are COPY'd into the runtime image.
# The wrapper server (/app/src/server.js) orchestrates OpenClaw and MC as
# child processes, proxying external traffic to their internal ports.
# ============================================================================

# Build openclaw from source to avoid npm packaging gaps (some dist files are not shipped).
FROM node:24-bookworm AS openclaw-build

# Dependencies needed for openclaw build
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    python3 \
    make \
    g++ \
  && rm -rf /var/lib/apt/lists/*

# Install Bun (openclaw build uses it)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /openclaw

# Pin to a known-good ref (tag/branch). Override in Northflank template settings if needed.
# Using a released tag avoids build breakage when `main` temporarily references unpublished packages.
ARG OPENCLAW_GIT_REF=v2026.3.13-1
RUN git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" https://github.com/openclaw/openclaw.git .

# Patch: relax version requirements for packages that may reference unpublished versions.
# Apply to all extension package.json files to handle workspace protocol (workspace:*).
RUN set -eux; \
  find ./extensions -name 'package.json' -type f | while read -r f; do \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
  done

RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install && pnpm ui:build


# ── Mission Control build stage ──────────────────────────────────
# Clones the gstack repo and builds two artifacts from missioncontrol/:
#   1. dist/missioncontrol  — compiled CLI binary (bun build --compile)
#   2. src/                 — TypeScript source, needed at runtime because
#      server.js runs the MC *server* via `bun run /missioncontrol/src/server.ts`
#      (the compiled binary is the CLI, not the server)
#
# NOTE: Build paths (/gstack/missioncontrol/...) differ from runtime paths
# (/missioncontrol/...) — the COPY instructions in the runtime stage perform
# this remapping.
FROM oven/bun:1 AS mc-build

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Pin to a known-good commit. Override GSTACK_GIT_REF to track a branch or tag.
ARG GSTACK_GIT_REF=feat/missioncontrol
RUN git clone --depth 1 --branch "${GSTACK_GIT_REF}" \
      https://github.com/developdaly/gstack.git /gstack

WORKDIR /gstack/missioncontrol

# Compile CLI to a self-contained binary
RUN bun build --compile src/cli.ts --outfile dist/missioncontrol


# Runtime image
FROM node:22-bookworm
ENV NODE_ENV=production

# ── System dependencies (Chromium libs for Puppeteer, tini for PID 1) ────
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    tini \
    python3 \
    python3-venv \
    libnspr4 \
    libnss3 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libasound2 \
    libpango-1.0-0 \
    libpangocairo-1.0-0 \
  && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI (official repo — https://github.com/cli/cli/blob/trunk/docs/install_linux.md#debian)
RUN mkdir -p -m 755 /etc/apt/keyrings \
 && wget -nv -O /etc/apt/keyrings/githubcli-archive-keyring.gpg \
      https://cli.github.com/packages/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# `openclaw update` expects pnpm. Provide it in the runtime image.
RUN corepack enable && corepack prepare pnpm@10.23.0 --activate

# Persist user-installed tools by default by targeting Northflank volume.
# - npm global installs -> /data/npm
# - pnpm global installs -> /data/pnpm (binaries) + /data/pnpm-store (store)
ENV NPM_CONFIG_PREFIX=/data/npm
ENV NPM_CONFIG_CACHE=/data/npm-cache
ENV PNPM_HOME=/data/pnpm
ENV PNPM_STORE_DIR=/data/pnpm-store
ENV PATH="/data/npm/bin:/data/pnpm:${PATH}"

# ── Wrapper application ──────────────────────────────────────────
WORKDIR /app

# Wrapper deps
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

# ── OpenClaw ─────────────────────────────────────────────────────
# Full built repo (including node_modules and dist/).
# server.js runs the entry point at /openclaw/dist/entry.js.
COPY --from=openclaw-build /openclaw /openclaw

# Provide an openclaw executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/entry.js "$@"' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw

# Bun runtime — used to run Mission Control's server.ts via `bun run`
COPY --from=oven/bun:1 /usr/local/bin/bun /usr/local/bin/bun
COPY --from=oven/bun:1 /usr/local/bin/bunx /usr/local/bin/bunx

# ── Mission Control artifacts ────────────────────────────────────
# Source path remapping: /gstack/missioncontrol/... → /missioncontrol/...
# Binary: CLI tool compiled from src/cli.ts
COPY --from=mc-build /gstack/missioncontrol/dist/missioncontrol /missioncontrol/dist/missioncontrol
# Source: server.ts is run via `bun run` at runtime (see startMissionControl in server.js)
COPY --from=mc-build /gstack/missioncontrol/src/ /missioncontrol/src/
RUN echo "built" > /missioncontrol/dist/.version

COPY src ./src

# The wrapper listens on $PORT.
# IMPORTANT: Do not set a default PORT here.
# Northflank injects PORT at runtime and routes traffic to that port.
# If we force a different port, deployments can come up but the domain will route elsewhere.
EXPOSE 8080

# Ensure PID 1 reaps zombies and forwards signals.
ENTRYPOINT ["tini", "-s", "--"]
CMD ["node", "src/server.js"]
