#!/bin/sh
# Template module remover for K.R.O.T. Hub
set -e

MODULE_ID="_template"
MODULE_NAME="Template"
BIN_PATH="/usr/bin/_template"
CONFIG_DIR="/etc/_template"

msg()  { printf '\033[32m%s\033[0m\n' "$1"; }

# Stop and disable service
if [ -x "/etc/init.d/$MODULE_ID" ]; then
    "/etc/init.d/$MODULE_ID" stop 2>/dev/null || true
    "/etc/init.d/$MODULE_ID" disable 2>/dev/null || true
fi

# Remove files
rm -f "/etc/init.d/$MODULE_ID"
rm -f "$BIN_PATH"
rm -rf "$CONFIG_DIR"
rm -f "/etc/config/$MODULE_ID"

# Remove via package manager if installed that way
if command -v opkg >/dev/null 2>&1; then
    if opkg list-installed 2>/dev/null | grep -q "^$MODULE_ID "; then
        opkg remove "$MODULE_ID" 2>/dev/null || true
    fi
fi

msg "$MODULE_NAME removed successfully"
