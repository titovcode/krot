#!/bin/sh
# OpenFlux Exit Node remover for K.R.O.T. Hub (same layout as hub/olcrtc).
# Keeps /etc/config/krot_openflux unless OF_PURGE=1 is set.
set -e

msg()  { printf '\033[32m%s\033[0m\n' "$1"; }

if [ -x /etc/init.d/krot-openflux ]; then
    msg "Stopping krot-openflux service..."
    /etc/init.d/krot-openflux stop >/dev/null 2>&1 || true
    /etc/init.d/krot-openflux disable >/dev/null 2>&1 || true
fi

# Drop the kernel-RST suppression rules (idempotent, no-op if absent).
command -v nft >/dev/null 2>&1 && nft delete table ip krot_openflux 2>/dev/null || true
command -v iptables >/dev/null 2>&1 && iptables -t filter -D OUTPUT -p tcp --tcp-flags RST RST -j KROT_OPENFLUX 2>/dev/null || true
command -v iptables >/dev/null 2>&1 && iptables -t filter -F KROT_OPENFLUX 2>/dev/null || true
command -v iptables >/dev/null 2>&1 && iptables -t filter -X KROT_OPENFLUX 2>/dev/null || true

# Make sure no runner/openflux process survives.
pkill -f 'openflux-run.sh' 2>/dev/null || true
pkill -f '(^|/)openflux --role=exit' 2>/dev/null || true
pkill -f '/usr/bin/openflux' 2>/dev/null || true

msg "Removing module files..."
rm -f /etc/init.d/krot-openflux
rm -f /www/cgi-bin/openflux
rm -rf /opt/openflux
rm -rf /etc/openflux
rm -rf /www/openflux

# 0.1.x layout leftovers (LuCI menu/acl/view, old payload dir).
rm -f /usr/share/luci/menu.d/krot-openflux.json
rm -f /usr/share/rpcd/acl.d/krot-openflux.json
rm -rf /www/luci-static/resources/view/krot-openflux
rm -rf /usr/lib/krot-openflux
rm -rf /tmp/luci-indexcache* 2>/dev/null || true

if [ "${OF_PURGE:-0}" = "1" ]; then
    msg "Purging config..."
    rm -f /etc/config/krot_openflux
else
    msg "Keeping /etc/config/krot_openflux (purge with: OF_PURGE=1 sh remove.sh)"
fi

printf '\033[32m%s\033[0m\n' "OpenFlux Exit Node removed"
