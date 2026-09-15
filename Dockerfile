# syntax=docker/dockerfile:1.7

# ── Common base with runtime deps ──────────────────────────────────────────
FROM node:26-trixie-slim AS base
WORKDIR /app

RUN --mount=type=cache,id=s/92ca8a61-c1ba-421f-a389-d48ac7258c2d-apt-cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,id=s/92ca8a61-c1ba-421f-a389-d48ac7258c2d-apt-lists,target=/var/lib/apt/lists,sharing=locked \
  apt-get update \
  && apt-get upgrade -y \
  && apt-get install -y --no-install-recommends \
      libsecret-1-0 \
      ca-certificates \
      python3 \
      python3-venv \
  && rm -rf /var/lib/apt/lists/*

# Refresh npm and patch bundled vulnerable dependencies.
RUN set -eux; \
  npm install -g npm@latest; \
  npm install --prefix /tmp/npm-cve-patch --no-audit --no-fund --ignore-scripts \
    --install-strategy=nested \
    brace-expansion@5.0.9 \
    ip-address@10.5.0 \
    tar@7.5.22 \
    undici@6.28.0; \
  for pkg in brace-expansion ip-address tar undici; do \
    test -d "/usr/local/lib/node_modules/npm/node_modules/$pkg"; \
    rm -rf "/usr/local/lib/node_modules/npm/node_modules/$pkg"; \
    cp -R "/tmp/npm-cve-patch/node_modules/$pkg" \
      "/usr/local/lib/node_modules/npm/node_modules/$pkg"; \
  done; \
  rm -rf /tmp/npm-cve-patch; \
  node -e "for (const p of ['brace-expansion','ip-address','tar','undici']) console.log(p, require('/usr/local/lib/node_modules/npm/node_modules/'+p+'/package.json').version);"; \
  npm --version; \
  npm cache clean --force


# ── Builder ────────────────────────────────────────────────────────────────
FROM base AS builder

ENV NEXT_TELEMETRY_DISABLED=1

RUN --mount=type=cache,id=s/92ca8a61-c1ba-421f-a389-d48ac7258c2d-apt-cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,id=s/92ca8a61-c1ba-421f-a389-d48ac7258c2d-apt-lists,target=/var/lib/apt/lists,sharing=locked \
  apt-get update \
  && apt-get install -y --no-install-recommends \
      python3 \
      make \
      g++ \
  && rm -rf /var/lib/apt/lists/*

COPY package*.json ./
COPY open-sse/package.json ./open-sse/package.json

COPY scripts/build/postinstall.mjs ./scripts/build/postinstall.mjs
COPY scripts/build/postinstallSupport.mjs ./scripts/build/postinstallSupport.mjs
COPY scripts/build/native-binary-compat.mjs ./scripts/build/native-binary-compat.mjs

ENV NPM_CONFIG_LEGACY_PEER_DEPS=true

RUN test -f package-lock.json \
  || (echo "package-lock.json is required for reproducible Docker builds" >&2 && exit 1)

RUN --mount=type=cache,id=s/92ca8a61-c1ba-421f-a389-d48ac7258c2d-npm-cache,target=/root/.npm \
  npm ci \
    --include=optional \
    --no-audit \
    --no-fund \
    --legacy-peer-deps \
    --ignore-scripts \
  && (cd node_modules/better-sqlite3 \
      && node /usr/local/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js rebuild) \
  && node -e "require('better-sqlite3')(':memory:').close()" \
  && node -e "const wreq=require('wreq-js'); if(typeof wreq.createTransport!=='function') process.exit(1)"


ARG OMNIROUTE_USE_TURBOPACK=0
ENV OMNIROUTE_USE_TURBOPACK="${OMNIROUTE_USE_TURBOPACK}"

ARG OMNIROUTE_BASE_PATH=""
ENV OMNIROUTE_BASE_PATH=$OMNIROUTE_BASE_PATH

ARG DASHBOARD_ALLOW_EMBED=""
ENV DASHBOARD_ALLOW_EMBED=$DASHBOARD_ALLOW_EMBED

ENV OMNIROUTE_MITM_STUB=1

ARG OMNIROUTE_BUILD_MEMORY_MB=3072
ENV NODE_OPTIONS="--max-old-space-size=${OMNIROUTE_BUILD_MEMORY_MB}"

ARG OMNIROUTE_BUILD_WORKERS=1
ENV CIRCLE_NODE_TOTAL=${OMNIROUTE_BUILD_WORKERS}

COPY . ./

RUN --mount=type=cache,id=s/92ca8a61-c1ba-421f-a389-d48ac7258c2d-next-cache,target=/app/.build/next/cache \
  mkdir -p /app/data \
  && npm run build \
  && node --input-type=module -e "import { createRequire } from 'node:module'; import { pathToFileURL } from 'node:url'; const standaloneRoot = '/app/.build/next/standalone/node_modules/'; const require = createRequire('/app/.build/next/standalone/package.json'); for (const pkg of ['@atjsh/llmlingua-2', '@huggingface/transformers', 'js-tiktoken']) { const resolved = require.resolve(pkg); if (!resolved.startsWith(standaloneRoot)) throw new Error(pkg + ' resolved outside standalone: ' + resolved); await import(pathToFileURL(resolved).href); } const onnxRuntime = require.resolve('onnxruntime-node'); if (!onnxRuntime.startsWith(standaloneRoot)) throw new Error('onnxruntime-node resolved outside standalone: ' + onnxRuntime); await import(pathToFileURL(onnxRuntime).href);"


# ── Runner base ────────────────────────────────────────────────────────────
FROM base AS runner-base

LABEL org.opencontainers.image.title="omniroute" \
  org.opencontainers.image.description="Unified AI proxy — route any LLM through one endpoint" \
  org.opencontainers.image.url="https://omniroute.online" \
  org.opencontainers.image.source="https://github.com/diegosouzapw/OmniRoute" \
  org.opencontainers.image.licenses="MIT"

ENV NODE_ENV=production
ENV PORT=20128
ENV HOSTNAME=0.0.0.0

ENV OMNIROUTE_MEMORY_MB=384
ENV NODE_OPTIONS="--max-old-space-size=384"

ENV DATA_DIR=/app/data

# ── Hugging Face persistent storage ────────────────────────────────────────
ENV HF_BUCKET=hf://buckets/hfdevhere/omniroute

RUN mkdir -p /app/data /app/scripts

# Install Hugging Face CLI in an isolated virtual environment.
RUN python3 -m venv /opt/huggingface \
  && /opt/huggingface/bin/pip install \
      --no-cache-dir \
      --upgrade \
      huggingface_hub \
  && ln -s /opt/huggingface/bin/hf /usr/local/bin/hf \
  && hf --help >/dev/null


# ── OmniRoute standalone application ───────────────────────────────────────
COPY --from=builder /app/.build/next/standalone ./

COPY --from=builder /app/node_modules/better-sqlite3 \
  ./node_modules/better-sqlite3

ENV OMNIROUTE_MIGRATIONS_DIR=/app/migrations

COPY --from=builder /app/scripts/dev/healthcheck.mjs ./healthcheck.mjs


# ── Render persistence startup script ──────────────────────────────────────
RUN cat > /app/scripts/render-entrypoint.sh <<'EOF'
#!/bin/sh

set -eu

DATA_DIR="${DATA_DIR:-/app/data}"
HF_BUCKET="${HF_BUCKET:-hf://buckets/hfdevhere/omniroute}"

DB="$DATA_DIR/storage.sqlite"

echo "=============================================="
echo " OmniRoute"
echo " Render Free + Hugging Face persistence"
echo "=============================================="

mkdir -p "$DATA_DIR"

# ---------------------------------------------------------------------------
# Existing OmniRoute permission check
# ---------------------------------------------------------------------------

if [ -x /app/check-permissions.sh ]; then
    /app/check-permissions.sh || true
fi

# ---------------------------------------------------------------------------
# Hugging Face authentication
# ---------------------------------------------------------------------------

if [ -n "${HF_TOKEN:-}" ]; then

    echo "[HF] Authenticating..."

    hf auth login \
        --token "$HF_TOKEN" \
        --add-to-git-credential=false \
        >/dev/null 2>&1 || {
            echo "[HF] Authentication failed."
            echo "[HF] OmniRoute will continue without persistence."
        }

    # -----------------------------------------------------------------------
    # Restore database
    # -----------------------------------------------------------------------

    if [ ! -f "$DB" ]; then

        echo "[HF] Checking for existing database..."

        if hf buckets cp \
            "$HF_BUCKET/storage.sqlite" \
            "$DB"; then

            echo "[HF] Database restored successfully."

        else

            echo "[HF] No database found in bucket."
            echo "[HF] OmniRoute will create a new database."

        fi

    else

        echo "[HF] Local database already exists."
        echo "[HF] Skipping restore."

    fi

else

    echo "[HF] HF_TOKEN is not configured."
    echo "[HF] Persistent database synchronization disabled."

fi

# ---------------------------------------------------------------------------
# Periodic SQLite backup
#
# Uses better-sqlite3's native backup mechanism rather than copying the
# SQLite file while it may be in use.
# ---------------------------------------------------------------------------

cat > /tmp/omniroute-backup.mjs <<'NODEEOF'
import fs from "node:fs";
import path from "node:path";

const dataDir = process.env.DATA_DIR || "/app/data";
const dbPath = path.join(dataDir, "storage.sqlite");
const tempPath = path.join(dataDir, ".storage-backup.sqlite");

if (!fs.existsSync(dbPath)) {
  process.exit(0);
}

try {
  const Database = require(
    "/app/node_modules/better-sqlite3"
  );

  const source = new Database(dbPath, {
    readonly: true
  });

  await source.backup(tempPath);

  source.close();

  console.log("[HF] SQLite backup snapshot created.");

} catch (error) {

  console.error(
    "[HF] SQLite backup failed:",
    error?.message || error
  );

  process.exit(1);
}
NODEEOF

# ---------------------------------------------------------------------------
# Background backup loop
# ---------------------------------------------------------------------------

(
    while true; do

        sleep "${HF_BACKUP_INTERVAL:-300}"

        if [ -z "${HF_TOKEN:-}" ]; then
            continue
        fi

        if [ ! -f "$DB" ]; then
            continue
        fi

        echo "[HF] Creating SQLite backup..."

        if node /tmp/omniroute-backup.mjs; then

            if [ -f "$DATA_DIR/.storage-backup.sqlite" ]; then

                echo "[HF] Uploading database..."

                if hf buckets cp \
                    "$DATA_DIR/.storage-backup.sqlite" \
                    "$HF_BUCKET/storage.sqlite"; then

                    echo "[HF] Database successfully synchronized."

                    # -------------------------------------------------------
                    # Timestamped backup
                    # -------------------------------------------------------

                    TIMESTAMP="$(date -u +"%Y-%m-%d_%H-%M-%S")"

                    if hf buckets cp \
                        "$DATA_DIR/.storage-backup.sqlite" \
                        "$HF_BUCKET/backups/storage-${TIMESTAMP}.sqlite"; then

                        echo "[HF] Historical backup uploaded."

                    else

                        echo "[HF] Historical backup upload failed."

                    fi

                else

                    echo "[HF] Database upload failed."

                fi

                rm -f "$DATA_DIR/.storage-backup.sqlite"

            fi

        fi

    done
) &

BACKUP_PID=$!

echo "[HF] Background backup process started."
echo "[HF] Backup interval: ${HF_BACKUP_INTERVAL:-300} seconds."

# ---------------------------------------------------------------------------
# Start OmniRoute
# ---------------------------------------------------------------------------

echo "[OmniRoute] Starting..."

exec "$@"
EOF

RUN chmod +x /app/scripts/render-entrypoint.sh


# ── Permission checker ─────────────────────────────────────────────────────
COPY --chmod=755 scripts/check-permissions.sh /app/check-permissions.sh


# ── Runtime ownership ──────────────────────────────────────────────────────
RUN chown -R node:node /app


# ── Health check ───────────────────────────────────────────────────────────
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["node", "healthcheck.mjs"]


EXPOSE 20128

USER node

ENTRYPOINT ["/app/scripts/render-entrypoint.sh"]

CMD ["node", "dev/run-standalone.mjs"]


# ── Runner Web ──────────────────────────────────────────────────────────────
FROM runner-base AS runner-web

USER root

COPY --from=builder /app/node_modules/playwright-core \
  ./node_modules/playwright-core

COPY --from=builder /app/node_modules/playwright \
  ./node_modules/playwright

ENV PLAYWRIGHT_BROWSERS_PATH=/home/node/.cache/ms-playwright

RUN --mount=type=cache,id=s/92ca8a61-c1ba-421f-a389-d48ac7258c2d-apt-cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,id=s/92ca8a61-c1ba-421f-a389-d48ac7258c2d-apt-lists,target=/var/lib/apt/lists,sharing=locked \
  apt-get update \
  && node node_modules/playwright/cli.js install chromium --with-deps \
  && chown -R node:node /home/node/.cache \
  && rm -rf /var/lib/apt/lists/*

RUN chown -R node:node /app

USER node


# ── Runner CLI ──────────────────────────────────────────────────────────────
FROM runner-base AS runner-cli

USER root

COPY --from=builder /app/node_modules/playwright-core \
  ./node_modules/playwright-core

COPY --from=builder /app/node_modules/playwright \
  ./node_modules/playwright

RUN --mount=type=cache,id=s/92ca8a61-c1ba-421f-a389-d48ac7258c2d-apt-cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,id=s/92ca8a61-c1ba-421f-a389-d48ac7258c2d-apt-lists,target=/var/lib/apt/lists,sharing=locked \
  apt-get update \
  && apt-get install -y --no-install-recommends \
      git \
      ca-certificates \
      docker.io \
      docker-compose \
  && rm -rf /var/lib/apt/lists/* \
  && git config --system \
      url."https://github.com/".insteadOf \
      "ssh://git@github.com/"

RUN --mount=type=cache,id=s/92ca8a61-c1ba-421f-a389-d48ac7258c2d-npm-cache,target=/root/.npm \
  npm install -g --no-audit --no-fund \
    @openai/codex@0.153.4 \
    @anthropic-ai/claude-code@2.1.260 \
    droid@0.212.0 \
    openclaw@2026.9.1

RUN chown -R node:node /app

USER node
