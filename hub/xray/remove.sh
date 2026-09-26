#!/bin/sh
# Xray-core remover for K.R.O.T. Hub
set -e

if [ -x /etc/init.d/xray ]; then
    /etc/init.d/xray stop 2>/dev/null || true
    /etc/init.d/xray disable 2>/dev/null || true
fi

rm -f /etc/init.d/xray
rm -f /usr/bin/xray
rm -rf /etc/xray
rm -f /etc/config/xray

if command -v opkg >/dev/null 2>&1; then
    if opkg list-installed | grep -q '^xray-core '; then
        opkg remove xray-core 2>/dev/null || true
    fi
fi

printf '\033[32m%s\033[0m\n' "Xray-core removed successfully"
