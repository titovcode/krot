#!/bin/sh
# AdGuard Home uninstaller for K.R.O.T. Hub
# Source: https://github.com/AdguardTeam/AdGuardHome
set -e

fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }
msg()  { printf '\033[32m%s\033[0m\n' "$1"; }

# Restore the DNS settings saved by install.sh, falling back to 1.1.1.1/udp.
restore_krot_dns() {
    command -v uci >/dev/null 2>&1 || return 0

    PREV_DNS_SERVER="$(uci -q get krot.settings.adguard_prev_dns_server 2>/dev/null || true)"
    PREV_DNS_TYPE="$(uci -q get krot.settings.adguard_prev_dns_type 2>/dev/null || true)"
    [ -n "$PREV_DNS_SERVER" ] || PREV_DNS_SERVER="1.1.1.1"
    [ -n "$PREV_DNS_TYPE" ] || PREV_DNS_TYPE="udp"

    msg "Restoring K.R.O.T. DNS to ${PREV_DNS_SERVER} (${PREV_DNS_TYPE})..."
    uci -q set krot.settings.dns_server="$PREV_DNS_SERVER"
    uci -q set krot.settings.dns_type="$PREV_DNS_TYPE"
    uci -q delete krot.settings.adguard_prev_dns_server 2>/dev/null || true
    uci -q delete krot.settings.adguard_prev_dns_type 2>/dev/null || true
    uci -q commit krot
}

if [ ! -x /opt/AdGuardHome/AdGuardHome ]; then
    msg "AdGuard Home is not installed"
    # Even if not installed, restore K.R.O.T. defaults in case UCI is still pointing at it
    if command -v uci >/dev/null 2>&1; then
        if [ "$(uci -q get krot.settings.dns_server 2>/dev/null || true)" = "127.0.0.1:5353" ]; then
            restore_krot_dns
            /etc/init.d/krot reload 2>/dev/null || /etc/init.d/krot restart 2>/dev/null || true
        fi
    fi
    exit 0
fi

msg "Stopping AdGuard Home..."
/opt/AdGuardHome/AdGuardHome -s stop 2>/dev/null || true

msg "Uninstalling AdGuard Home service..."
/opt/AdGuardHome/AdGuardHome -s uninstall 2>/dev/null || true

msg "Removing AdGuard Home files..."
rm -rf /opt/AdGuardHome
rm -rf /opt/AdGuardHome.yaml 2>/dev/null || true

# Restore K.R.O.T. DNS to what the user had before AdGuard was installed
restore_krot_dns
# K.R.O.T. will be restarted by the Hub installer (updater.sh) so sing-box
# picks up the restored dns_server / dns_type. No restart here.

msg "AdGuard Home removed"
