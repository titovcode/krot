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

msg "Installing HaGeZi — DNS Blocklists..."

# Check if K.R.O.T. is installed
if ! command -v krot >/dev/null 2>&1; then
    fail "K.R.O.T. is not installed"
fi

# Set default UCI config. On reinstall (Hub "Update" re-runs this script)
# keep the user's enabled/list choices — only set defaults when missing.
if ! uci -q get krot.settings.hagezi_enabled >/dev/null 2>&1; then
    uci -q set krot.settings.hagezi_enabled='0'
fi
LIST="$(uci -q get krot.settings.hagezi_list 2>/dev/null || true)"
case "$LIST" in
    multi|pro|ultimate) ;;
    *) LIST="$DEFAULT_LIST" ;;
esac
uci -q set krot.settings.hagezi_list="$LIST"
uci -q set krot.settings.hagezi_last_update='never'
uci -q set krot.settings.hagezi_domains_count='0'
uci -q commit krot

# Download the selected list (direct or via K.R.O.T. proxy)
msg "Downloading HaGeZi $LIST blocklist..."
LIST_FILE="$HAGEZI_DIR/$LIST.txt"
if ! http_download "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/$LIST.txt" "$LIST_FILE"; then
    fail "Failed to download blocklist. GitHub may be blocked: enable 'Download lists via Proxy/VPN' in K.R.O.T. Settings."
fi

# Validate download
if [ ! -s "$LIST_FILE" ]; then
    fail "Downloaded file is empty"
fi

# Count domains (lines starting with ||)
DOMAIN_COUNT="$(grep -c '^||' "$LIST_FILE" 2>/dev/null)"
[ -n "$DOMAIN_COUNT" ] || DOMAIN_COUNT=0
msg "Blocklist contains $DOMAIN_COUNT domains"

# Create symlink for current list
ln -sf "$LIST_FILE" "$HAGEZI_DIR/current.txt"

# Generate sing-box rule_set file for DNS blocking
msg "Generating sing-box rule_set..."
generate_singbox_ruleset "$LIST_FILE" "$HAGEZI_DIR/ruleset.json"

# Compile to binary format for fast loading by sing-box
msg "Compiling rule_set to binary format..."
if sing-box rule-set compile "$HAGEZI_DIR/ruleset.json" -o "$HAGEZI_DIR/ruleset.srs" 2>/dev/null; then
    rm -f "$HAGEZI_DIR/ruleset.json"
    msg "Compiled rule_set: $(wc -c < "$HAGEZI_DIR/ruleset.srs") bytes"
else
    msg "Warning: sing-box rule-set compile failed, keeping JSON format"
    # JSON format will still work, just slower to load
fi

# Save metadata
uci -q set krot.settings.hagezi_domains_count="$DOMAIN_COUNT"
uci -q set krot.settings.hagezi_last_update="$(date '+%Y-%m-%d %H:%M')"
uci -q commit krot

# Save version for system info
echo "1.0" > "$HAGEZI_DIR/version"

msg "HaGeZi — DNS Blocklists installed successfully"
msg ""
msg "To enable ad blocking:"
msg "  1. Go to K.R.O.T. → Settings → DNS"
msg "  2. Check 'Enable HaGeZi ad blocking'"
msg "  3. Select blocklist (Normal/Pro/Ultimate)"
msg "  4. Save & Apply"
msg ""
msg "The blocklist will be updated automatically with K.R.O.T. list updates."
