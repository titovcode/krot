#!/bin/sh
# OpenFlux Exit Node updater for K.R.O.T. Hub.
# Re-runs install.sh from the module repo: it preserves /etc/config/krot_openflux
# and picks up the binary via bin_base / /tmp/openflux when present.
set -e

OF_REPO="${OF_REPO:-titovcode/krot}"
OF_BRANCH="${OF_BRANCH:-main}"
URL="https://raw.githubusercontent.com/${OF_REPO}/${OF_BRANCH}/hub/openflux/install.sh"

TMP="$(mktemp /tmp/openflux-update.XXXXXX 2>/dev/null || echo /tmp/openflux-update.$$)"
trap 'rm -f "$TMP"' EXIT HUP INT TERM

if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 30 "$URL" -o "$TMP"
else
    wget -qO "$TMP" --timeout=30 "$URL"
fi

[ -s "$TMP" ] || { echo "Failed to download install.sh from $URL" >&2; exit 1; }

sh "$TMP"
