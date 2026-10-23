#!/bin/sh
# HaGeZi — DNS Blocklists installer for K.R.O.T. Hub
# Source: https://github.com/hagezi/dns-blocklists
set -e

fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }
msg()  { printf '\033[32m%s\033[0m\n' "$1"; }

HAGEZI_DIR="/etc/krot/hagezi"
mkdir -p "$HAGEZI_DIR"

# Default blocklist: Multi NORMAL (good balance, few false positives)
DEFAULT_LIST="multi"
DEFAULT_LIST_NAME="Multi NORMAL"

msg "Installing HaGeZi — DNS Blocklists..."

# Check if K.R.O.T. is installed
if ! command -v krot >/dev/null 2>&1; then
    fail "K.R.O.T. is not installed"
fi

# Create initial config
uci -q set krot.settings.hagezi_enabled='0'
uci -q set krot.settings.hagezi_list="$DEFAULT_LIST"
uci -q set krot.settings.hagezi_last_update=''
uci -q set krot.settings.hagezi_domains_count='0'
uci -q commit krot

# Download the default list
msg "Downloading HaGeZi $DEFAULT_LIST_NAME blocklist..."
case "$DEFAULT_LIST" in
    multi)    LIST_URL="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/multi.txt" ;;
    pro)      LIST_URL="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt" ;;
    ultimate) LIST_URL="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/ultimate.txt" ;;
    *)        fail "Unknown list: $DEFAULT_LIST" ;;
esac

# Download via K.R.O.T. proxy if available, otherwise direct
if uci -q get krot.settings.download_lists_via_proxy 2>/dev/null | grep -q '1'; then
    # Use sing-box proxy for GitHub (GitHub may be blocked)
    if curl -sL --connect-timeout 10 --max-time 30 \
        --proxy "http://127.0.0.1:4534" \
        "$LIST_URL" -o "$HAGEZI_DIR/$DEFAULT_LIST.txt" 2>/dev/null; then
        msg "Downloaded via K.R.O.T. proxy"
    else
        fail "Failed to download via proxy. Check your internet connection."
    fi
else
    # Direct download
    if curl -sL --connect-timeout 10 --max-time 30 \
        "$LIST_URL" -o "$HAGEZI_DIR/$DEFAULT_LIST.txt" 2>/dev/null; then
        msg "Downloaded directly"
    else
        fail "Failed to download. GitHub may be blocked. Enable 'Download lists via Proxy/VPN' in K.R.O.T. Settings."
    fi
fi

# Validate download
if [ ! -s "$HAGEZI_DIR/$DEFAULT_LIST.txt" ]; then
    fail "Downloaded file is empty"
fi

# Count domains (lines starting with ||)
DOMAIN_COUNT=$(grep -c '^||' "$HAGEZI_DIR/$DEFAULT_LIST.txt" 2>/dev/null || echo 0)
msg "Blocklist contains $DOMAIN_COUNT domains"

# Save metadata
uci -q set krot.settings.hagezi_domains_count="$DOMAIN_COUNT"
uci -q set krot.settings.hagezi_last_update="$(date '+%Y-%m-%d %H:%M')"
uci -q commit krot

# Save version for system info
echo "1.0" > /etc/krot/hagezi/version

# Create symlink for current list
ln -sf "$HAGEZI_DIR/$DEFAULT_LIST.txt" "$HAGEZI_DIR/current.txt"

msg "HaGeZi — DNS Blocklists installed successfully"
msg ""
msg "To enable ad blocking:"
msg "  1. Go to K.R.O.T. → Settings → DNS"
msg "  2. Check 'Enable HaGeZi ad blocking'"
msg "  3. Select blocklist (Normal/Pro/Ultimate)"
msg "  4. Save & Apply"
msg ""
msg "The blocklist will be updated automatically with K.R.O.T. list updates."
