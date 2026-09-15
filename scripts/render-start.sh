#!/bin/sh

set -eu

/app/check-permissions.sh

DATA_DIR="${DATA_DIR:-/app/data}"
BUCKET="${HF_BUCKET:-hf://buckets/hfdevhere/omniroute}"

mkdir -p "$DATA_DIR"

echo "========================================"
echo " OmniRoute + Hugging Face Persistence"
echo "========================================"

if [ -z "${HF_TOKEN:-}" ]; then
    echo "[HF] HF_TOKEN is not configured."
else
    hf auth login \
        --token "$HF_TOKEN" \
        --add-to-git-credential=false

    if hf buckets cp \
        "$BUCKET/storage.sqlite" \
        "$DATA_DIR/storage.sqlite"; then

        echo "[HF] Database restored."

    else

        echo "[HF] No existing database found."
        echo "[HF] Starting with a new database."

    fi
fi

exec "$@"