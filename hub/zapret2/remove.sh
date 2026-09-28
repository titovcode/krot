#!/bin/sh
# zapret2 module removal script for K.R.O.T. Hub
# Removes the zapret2 provider files from /opt/zapret

set -e

ZAPRET_DIR="/opt/zapret"

msg() {
    echo "[zapret2-remove] $*"
}

# Stop any running nfqws processes that K.R.O.T. may have started
msg "Stopping zapret2 provider processes..."
for pidfile in /var/run/krot/zapret*.pid /var/run/zapret*.pid; do
    [ -f "$pidfile" ] || continue
    pid="$(cat "$pidfile" 2>/dev/null)" || continue
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -f "$pidfile"
done

# Kill any remaining nfqws processes (zapret2 uses nfqws2 binary name)
pkill -f "nfqws2" 2>/dev/null || true
pkill -f "/opt/zapret/nfq/nfqws" 2>/dev/null || true

# Remove the provider directory
if [ -d "$ZAPRET_DIR" ]; then
    msg "Removing $ZAPRET_DIR..."
    rm -rf "$ZAPRET_DIR"
fi

# Clean up state directories
rm -rf /var/run/krot/zapret 2>/dev/null || true
rm -rf /tmp/krot/zapret 2>/dev/null || true

msg "Zapret2 provider removed"
msg "Note: K.R.O.T. will need a different DPI bypass provider (zapret or byedpi)"
msg "or the rules using 'zapret' action will fail until one is installed."
