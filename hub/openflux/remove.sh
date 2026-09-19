#!/bin/sh
# OpenFlux Exit Node uninstaller for K.R.O.T. Hub
#
# By default keeps /etc/krot-openflux (state) and /etc/config/krot_openflux so a
# reinstall does not lose settings. Purge everything with:
#   OF_PURGE=1 sh remove.sh
set -e

msg()  { printf '\033[32m%s\033[0m\n' "$1"; }

if [ -x /etc/init.d/krot-openflux ]; then
    msg "Stopping krot-openflux service..."
    /etc/init.d/krot-openflux stop >/dev/null 2>&1 || true
    /etc/init.d/krot-openflux disable >/dev/null 2>&1 || true
fi

# Make sure no openflux process is left running.
pkill -f 'openflux-run.sh' 2>/dev/null || true
pkill -f '(^|/)openflux --role=exit' 2>/dev/null || true

# Drop the RST-suppression firewall rules (idempotent, no-op if absent).
command -v nft >/dev/null 2>&1 && nft delete table ip krot_openflux 2>/dev/null || true
command -v iptables >/dev/null 2>&1 && iptables -t filter -D OUTPUT -p tcp --tcp-flags RST RST -j KROT_OPENFLUX 2>/dev/null || true
command -v iptables >/dev/null 2>&1 && iptables -t filter -F KROT_OPENFLUX 2>/dev/null || true
command -v iptables >/dev/null 2>&1 && iptables -t filter -X KROT_OPENFLUX 2>/dev/null || true

msg "Removing module files..."
rm -f /etc/init.d/krot-openflux
rm -f /usr/share/luci/menu.d/krot-openflux.json
rm -f /usr/share/rpcd/acl.d/krot-openflux.json
rm -rf /www/luci-static/resources/view/krot-openflux
rm -rf /usr/lib/krot-openflux
rm -rf /var/run/krot-openflux

if [ "${OF_PURGE:-0}" = "1" ]; then
    msg "Purging config and state..."
    rm -rf /etc/krot-openflux
    rm -f /etc/config/krot_openflux
else
    msg "Keeping /etc/krot-openflux and /etc/config/krot_openflux"
    msg "Purge them with: OF_PURGE=1 sh remove.sh"
fi

/etc/init.d/rpcd restart >/dev/null 2>&1 || true

msg "OpenFlux Exit Node removed"
