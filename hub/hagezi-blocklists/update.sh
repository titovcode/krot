#!/bin/sh
# HaGeZi — DNS Blocklists updater for K.R.O.T. Hub
# Called by K.R.O.T. list_update mechanism
set -e

fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }
msg()  { printf '\033[32m%s\033[0m\n' "$1"; }

HAGEZI_DIR="/etc/krot/hagezi"
mkdir -p "$HAGEZI_DIR"

# K.R.O.T. local proxy for downloads (GitHub may be blocked)
PROXY_ADDR=""
if command -v uci >/dev/null 2>&1 && [ -f /etc/config/krot ]; then
    if uci -q get krot.settings.download_lists_via_proxy 2>/dev/null | grep -q '1'; then
        PROXY_ADDR="http://127.0.0.1:4534"
    fi
fi

# Download a URL to a file, via the K.R.O.T. proxy when enabled
http_download() {
    if [ -n "$PROXY_ADDR" ] && command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 120 -x "$PROXY_ADDR" "$1" -o "$2"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 120 "$1" -o "$2"
    elif [ -n "$PROXY_ADDR" ] && command -v wget >/dev/null 2>&1; then
        http_proxy="$PROXY_ADDR" https_proxy="$PROXY_ADDR" wget -qO "$2" --timeout=120 "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$2" --timeout=120 "$1"
    else
        fail "wget or curl is required"
    fi
}

# Generate a sing-box source rule-set JSON from an AdBlock-style list (||domain^).
# Used by configure_hagezi_dns_blocklist_v2 in podkop.
# Usage: generate_singbox_ruleset <input.txt> <output.json>
generate_singbox_ruleset() {
    local input="$1"
    local output="$2"
    local tmp_output="$output.tmp"

    # Start JSON (version 3, same format as rulesets.uc create-source)
    echo '{"version":3,"rules":[{"domain_suffix":[' > "$tmp_output"

    # Add domains (comma-separated, quoted), stripping ||domain^ AdBlock syntax
    grep '^||' "$input" 2>/dev/null | \
        sed 's/^||//; s/\^.*//' | \
        sort -u | \
        awk 'BEGIN{first=1} {if(!first) printf ","; printf "\"%s\"", $0; first=0}' >> "$tmp_output"

    # Close JSON
    echo ']}]}' >> "$tmp_output"

    # Validate result (basic check)
    if [ -s "$tmp_output" ]; then
        mv "$tmp_output" "$output"
        msg "Generated rule_set: $(wc -c < "$output") bytes"
    else
        rm -f "$tmp_output"
        fail "Failed to generate rule_set"
    fi
}

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
if ! http_download "$URL" "$TMP_FILE"; then
    rm -f "$TMP_FILE"
    fail "Failed to download blocklist. GitHub may be blocked: enable 'Download lists via Proxy/VPN' in K.R.O.T. Settings."
fi

# Validate
if [ ! -s "$TMP_FILE" ]; then
    rm -f "$TMP_FILE"
    fail "Downloaded file is empty"
fi

# Count domains
DOMAIN_COUNT="$(grep -c '^||' "$TMP_FILE" 2>/dev/null)"
[ -n "$DOMAIN_COUNT" ] || DOMAIN_COUNT=0

# Replace old file
mv "$TMP_FILE" "$HAGEZI_DIR/$LIST.txt"
ln -sf "$HAGEZI_DIR/$LIST.txt" "$HAGEZI_DIR/current.txt"

# Generate sing-box rule_set file for DNS blocking
msg "Generating sing-box rule_set..."
generate_singbox_ruleset "$HAGEZI_DIR/$LIST.txt" "$HAGEZI_DIR/ruleset.json"

# Compile to binary format for fast loading by sing-box
msg "Compiling rule_set to binary format..."
if sing-box rule-set compile "$HAGEZI_DIR/ruleset.json" -o "$HAGEZI_DIR/ruleset.srs" 2>/dev/null; then
    rm -f "$HAGEZI_DIR/ruleset.json"
    msg "Compiled rule_set: $(wc -c < "$HAGEZI_DIR/ruleset.srs") bytes"
else
    msg "Warning: sing-box rule-set compile failed, keeping JSON format"
    # JSON format will still work, just slower to load
fi

# Update metadata
uci -q set krot.settings.hagezi_domains_count="$DOMAIN_COUNT"
uci -q set krot.settings.hagezi_last_update="$(date '+%Y-%m-%d %H:%M')"
uci -q commit krot

# Save version for system info
echo "1.0" > "$HAGEZI_DIR/version"

msg "Updated: $DOMAIN_COUNT domains blocked"
