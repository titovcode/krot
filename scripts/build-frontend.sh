#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FRONTEND_DIR="$ROOT_DIR/fe-app-podkop"

if [ ! -d "$FRONTEND_DIR/node_modules" ]; then
    echo "Installing frontend dependencies..." >&2
    (cd "$FRONTEND_DIR" && yarn install --frozen-lockfile)
fi

echo "Building frontend..." >&2
(cd "$FRONTEND_DIR" && yarn build)

echo "Frontend built successfully" >&2
