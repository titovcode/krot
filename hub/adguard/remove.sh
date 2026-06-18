#!/bin/sh
# AdGuard Home uninstaller for K.R.O.T. Hub
# Source: https://github.com/AdguardTeam/AdGuardHome
set -e

fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }
msg()  { printf '\033[32m%s\033[0m\n' "$1"; }

if [ ! -x /opt/AdGuardHome/AdGuardHome ]; then
    msg "AdGuard Home is not installed"
    # Even if not installed, restore K.R.O.T. defaults in case UCI is still pointing at it
    if command -v uci >/dev/null 2>&1; then
        if [ "$(uci -q get krot.settings.dns_server 2>/dev/null || true)" = "127.0.0.1:5353" ]; then
            msg "Restoring K.R.O.T. DNS to 1.1.1.1..."
            uci -q set krot.settings.dns_server='1.1.1.1'
            uci -q commit krot
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

# Restore K.R.O.T. DNS to a safe public default
if command -v uci >/dev/null 2>&1; then
    msg "Restoring K.R.O.T. DNS to 1.1.1.1..."
    uci -q set krot.settings.dns_server='1.1.1.1'
    uci -q commit krot
    /etc/init.d/krot reload 2>/dev/null || /etc/init.d/krot restart 2>/dev/null || true
fi

msg "AdGuard Home removed"
msg "K.R.O.T. DNS is now 1.1.1.1"
