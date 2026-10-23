#!/bin/sh
# HaGeZi — DNS Blocklists remover for K.R.O.T. Hub
set -e

fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }
msg()  { printf '\033[32m%s\033[0m\n' "$1"; }

HAGEZI_DIR="/etc/krot/hagezi"

msg "Removing HaGeZi — DNS Blocklists..."

# Disable in K.R.O.T. config
if command -v uci >/dev/null 2>&1; then
    msg "Disabling ad blocking in K.R.O.T. settings..."
    uci -q set krot.settings.hagezi_enabled='0'
    uci -q delete krot.settings.hagezi_list 2>/dev/null || true
    uci -q delete krot.settings.hagezi_last_update 2>/dev/null || true
    uci -q delete krot.settings.hagezi_domains_count 2>/dev/null || true
    uci -q commit krot
fi

# Remove downloaded lists
msg "Removing downloaded blocklists..."
rm -rf "$HAGEZI_DIR"

# K.R.O.T. will be restarted by the Hub installer (updater.sh)
# so the DNS changes take effect. No restart here.

msg "HaGeZi — DNS Blocklists removed"
msg "Ad blocking is now disabled."
