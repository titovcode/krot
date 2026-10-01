#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_VERSION="${1:-0.0.8.12}"
OUTPUT_DIR="${2:-$SCRIPT_DIR/dist/release-final}"
IMAGE_TAG="krot-builder:${RELEASE_VERSION}"

echo "Building Docker image ${IMAGE_TAG}..."
docker build -f "$SCRIPT_DIR/Dockerfile.build" -t "$IMAGE_TAG" "$SCRIPT_DIR"

echo "Running K.R.O.T. release build ${RELEASE_VERSION}..."
mkdir -p "$OUTPUT_DIR"
docker run --rm \
    -v "$SCRIPT_DIR:/build:rw" \
    -v "$OUTPUT_DIR:/build/dist/release-final:rw" \
    -e "SOURCE_ROOT_DIR=/build" \
    -e "WINDOWS_ARTIFACTS_DIR=/build/dist/release-final" \
    "$IMAGE_TAG" \
    "$RELEASE_VERSION" \
    "/build/dist/release-final"

echo "Build complete. Artifacts in: $OUTPUT_DIR"
