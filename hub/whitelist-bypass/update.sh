#!/bin/sh
# Update = reinstall payload + binaries for K.R.O.T. Hub.
# The Hub UI calls hub_install_<id> for the "Update" action; this script exists
# for CLI use and forwards to install.sh from the same source.
set -e

WLB_REPO="${WLB_REPO:-titovcode/krot}"
WLB_BRANCH="${WLB_BRANCH:-main}"
URL="https://raw.githubusercontent.com/${WLB_REPO}/${WLB_BRANCH}/hub/whitelist-bypass/install.sh"

TMP="$(mktemp /tmp/wlb-update.XXXXXX 2>/dev/null || echo /tmp/wlb-update.$$)"
trap 'rm -f "$TMP"' EXIT HUP INT TERM

if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 30 "$URL" -o "$TMP"
else
    wget -qO "$TMP" --timeout=30 "$URL"
fi

[ -s "$TMP" ] || { echo "Failed to download install.sh from $URL" >&2; exit 1; }

sh "$TMP"
