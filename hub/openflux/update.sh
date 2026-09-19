#!/bin/sh
# Update = reinstall payload + binary for K.R.O.T. Hub.
# The Hub UI calls hub_install_<id> for the "Update" action; this script exists
# for CLI use and forwards to install.sh from the same source.
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
