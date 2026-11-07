#!/bin/bash
# Dev-deploy of K.R.O.T. files to the router over SSH, mirroring what the
# package build does (version placeholder substitution included).
# Usage: ./scripts/deploy-dev.sh [router_ip]
set -euo pipefail

ROUTER="${1:-192.168.1.1}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Version the same way the Makefiles resolve it: prefer env, fall back to the
# installed krot package version on the router.
VERSION="${PODKOP_PACKAGE_VERSION:-${PODKOP_VERSION:-}}"
if [ -z "$VERSION" ]; then
    VERSION="$(ssh "root@$ROUTER" 'opkg status krot 2>/dev/null | sed -n "s/^Version: //p" | head -1')"
fi
if [ -z "$VERSION" ]; then
    echo "ERROR: could not determine version" >&2
    exit 1
fi
echo "Deploying to $ROUTER (version $VERSION)"

# Backend
scp "$REPO_ROOT/krot/files/usr/bin/podkop" "root@$ROUTER:/usr/bin/krot"
scp "$REPO_ROOT/krot/files/etc/init.d/podkop" "root@$ROUTER:/etc/init.d/krot"

# Backend libs: deploy every file present in the repo tree so new modules are
# never silently left behind (helpers.sh, nft.sh, rulesets*, subscription_*,
# sing_box_config_*, byedpi/zapret/dnsmasq/logging/provider_status, *.uc).
for f in "$REPO_ROOT"/krot/files/usr/lib/*; do
    [ -f "$f" ] || continue
    scp "$f" "root@$ROUTER:/usr/lib/krot/$(basename "$f")"
done

# LuCI app
for f in main.js podkop.js settings.js section.js server.js dashboard.js diagnostic.js updates.js monitoring.js local_devices.js; do
    src="$REPO_ROOT/luci-app-krot/htdocs/luci-static/resources/view/podkop/$f"
    [ -f "$src" ] && scp "$src" "root@$ROUTER:/www/luci-static/resources/view/krot/$f"
done

# Package-build substitutions (see luci-app-krot/Makefile)
ssh "root@$ROUTER" "
    chmod +x /usr/bin/krot /etc/init.d/krot /usr/lib/krot/automation.sh
    sed -i 's/__COMPILED_VERSION_VARIABLE__/$VERSION/g' \
        /www/luci-static/resources/view/krot/main.js \
        /usr/lib/krot/constants.sh
"

echo "Done. Deployed to /www/luci-static/resources/view/krot (version $VERSION)."
echo "Hard-refresh LuCI (Cmd+Shift+R) to pick up new JS."
