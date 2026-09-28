#!/bin/sh
# Template module updater for K.R.O.T. Hub
# Preserves user configs in /etc/_template/conf.d
set -e

MODULE_ID="_template"
MODULE_NAME="Template"
CONFIG_DIR="/etc/_template"

fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }
msg()  { printf '\033[32m%s\033[0m\n' "$1"; }

msg "Updating $MODULE_NAME..."

# Ensure config directory exists (preserve user configs)
mkdir -p "$CONFIG_DIR/conf.d"

# Update binary (same logic as install.sh)
# ... add your update logic here ...

# Restart service to pick up changes
if [ -x "/etc/init.d/$MODULE_ID" ]; then
    "/etc/init.d/$MODULE_ID" restart 2>/dev/null || true
fi

msg "$MODULE_NAME updated successfully"
