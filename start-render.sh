#!/bin/sh

set -eu

DATA_DIR="${DATA_DIR:-/app/data}"
BUCKET="${HF_BUCKET:-hf://buckets/hfdevhere/omniroute}"

mkdir -p "$DATA_DIR"

echo "======================================"
echo "        OmniRoute Render Startup"
echo "======================================"
echo "DATA_DIR: $DATA_DIR"
echo "BUCKET:   $BUCKET"

if [ -z "${HF_TOKEN:-}" ]; then
    echo "WARNING: HF_TOKEN is not configured."
else
    echo "Logging into Hugging Face..."

    hf auth login \
        --token "$HF_TOKEN" \
        --add-to-git-credential=false
fi

echo "Checking for existing database..."

if [ -n "${HF_TOKEN:-}" ]; then

    if hf buckets cp \
        "$BUCKET/storage.sqlite" \
        "$DATA_DIR/storage.sqlite"; then

        echo "Existing database restored."

    else

        echo "No existing database found."
        echo "OmniRoute will create a new database."

    fi

else
    echo "Skipping database restore because HF_TOKEN is missing."
fi

echo "Starting OmniRoute..."

exec "$@"