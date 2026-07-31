#!/bin/sh
# Whitelist Bypass uninstaller for K.R.O.T. Hub
#
# By default keeps /etc/krot-wlb (cookies, saved conference links) so a
# reinstall does not force re-authorization. Purge everything with:
#   WLB_PURGE=1 sh remove.sh
set -e

msg()  { printf '\033[32m%s\033[0m\n' "$1"; }

if [ -x /etc/init.d/krot-wlb ]; then
    msg "Stopping krot-wlb service..."
    /etc/init.d/krot-wlb stop >/dev/null 2>&1 || true
    /etc/init.d/krot-wlb disable >/dev/null 2>&1 || true
fi

# Make sure no creator is left running.
pkill -f 'headless-.*-creator' 2>/dev/null || true

msg "Removing module files..."
rm -f /etc/init.d/krot-wlb
rm -f /usr/share/luci/menu.d/krot-wlb.json
rm -f /usr/share/rpcd/acl.d/krot-wlb.json
rm -rf /www/luci-static/resources/view/krot-wlb
rm -rf /usr/lib/krot-wlb
rm -rf /var/run/krot-wlb

if [ "${WLB_PURGE:-0}" = "1" ]; then
    msg "Purging config, cookies and saved links..."
    rm -rf /etc/krot-wlb
    rm -f /etc/config/krot_wlb
else
    msg "Keeping /etc/krot-wlb (cookies, saved links) and /etc/config/krot_wlb"
    msg "Purge them with: WLB_PURGE=1 sh remove.sh"
fi

/etc/init.d/rpcd restart >/dev/null 2>&1 || true

msg "Whitelist Bypass removed"
