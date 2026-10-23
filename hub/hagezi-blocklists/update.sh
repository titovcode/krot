#!/bin/sh
# HaGeZi — DNS Blocklists updater for K.R.O.T. Hub
# Called by K.R.O.T. list_update mechanism
set -e

fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }
msg()  { printf '\033[32m%s\033[0m\n' "$1"; }

HAGEZI_DIR="/etc/krot/hagezi"
mkdir -p "$HAGEZI_DIR"

# Get current settings
ENABLED="$(uci -q get krot.settings.hagezi_enabled 2>/dev/null || echo '0')"
LIST="$(uci -q get krot.settings.hagezi_list 2>/dev/null || echo 'multi')"

# Only update if enabled
if [ "$ENABLED" != "1" ]; then
    msg "HaGeZi ad blocking is disabled, skipping update"
    exit 0
fi

msg "Updating HaGeZi blocklist: $LIST..."

# Map list name to URL
case "$LIST" in
    multi)    URL="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/multi.txt" ;;
    pro)      URL="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt" ;;
    ultimate) URL="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/ultimate.txt" ;;
    *)        fail "Unknown list: $LIST" ;;
esac

# Download new version
TMP_FILE="$HAGEZI_DIR/$LIST.txt.new"
if curl -sL --connect-timeout 10 --max-time 60 \
    "$URL" -o "$TMP_FILE" 2>/dev/null; then
    
    # Validate
    if [ ! -s "$TMP_FILE" ]; then
        rm -f "$TMP_FILE"
        fail "Downloaded file is empty"
    fi
    
    # Count domains
    DOMAIN_COUNT=$(grep -c '^||' "$TMP_FILE" 2>/dev/null || echo 0)
    
    # Replace old file
    mv "$TMP_FILE" "$HAGEZI_DIR/$LIST.txt"
    ln -sf "$HAGEZI_DIR/$LIST.txt" "$HAGEZI_DIR/current.txt"
    
    # Update metadata
    uci -q set krot.settings.hagezi_domains_count="$DOMAIN_COUNT"
    uci -q set krot.settings.hagezi_last_update="$(date '+%Y-%m-%d %H:%M')"
    uci -q commit krot

    # Save version for system info
    echo "1.0" > /etc/krot/hagezi/version

    msg "Updated: $DOMAIN_COUNT domains blocked"
else
    rm -f "$TMP_FILE"
    fail "Failed to download blocklist"
fi
