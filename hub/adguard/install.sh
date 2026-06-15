#!/bin/sh
# AdGuard Home installer for K.R.O.T. Hub
# Source: https://github.com/AdguardTeam/AdGuardHome
set -e

GITHUB_API="https://api.github.com"
TMP_DIR="$(mktemp -d /tmp/hub-adguard.XXXXXX 2>/dev/null || { mkdir -p /tmp/hub-adguard.$$; echo /tmp/hub-adguard.$$; })"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM

fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }
msg()  { printf '\033[32m%s\033[0m\n' "$1"; }

# Detect proxy from K.R.O.T. settings
PROXY_ADDR=""
if command -v uci >/dev/null 2>&1 && [ -f /etc/config/krot ]; then
    if uci -q get krot.settings.download_lists_via_proxy 2>/dev/null | grep -q '1'; then
        PROXY_ADDR="http://127.0.0.1:4534"
    fi
fi

# Download helper with proxy support
http_get() {
    if command -v wget >/dev/null 2>&1; then
        if [ -n "$PROXY_ADDR" ]; then
            http_proxy="$PROXY_ADDR" https_proxy="$PROXY_ADDR" wget -qO- "$1"
        else
            wget -qO- "$1"
        fi
    elif command -v curl >/dev/null 2>&1; then
        if [ -n "$PROXY_ADDR" ]; then
            curl -fsSL -x "$PROXY_ADDR" "$1"
        else
            curl -fsSL "$1"
        fi
    else
        fail "wget or curl is required"
    fi
}

http_download() {
    if command -v wget >/dev/null 2>&1; then
        if [ -n "$PROXY_ADDR" ]; then
            http_proxy="$PROXY_ADDR" https_proxy="$PROXY_ADDR" wget -qO "$2" "$1"
        else
            wget -qO "$2" "$1"
        fi
    elif command -v curl >/dev/null 2>&1; then
        if [ -n "$PROXY_ADDR" ]; then
            curl -fsSL -x "$PROXY_ADDR" "$1" -o "$2"
        else
            curl -fsSL "$1" -o "$2"
        fi
    else
        fail "wget or curl is required"
    fi
}

# Detect architecture
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  AG_ARCH="amd64" ;;
    aarch64) AG_ARCH="arm64" ;;
    armv7*)  AG_ARCH="armv7" ;;
    mipsel*) AG_ARCH="mipsle" ;;
    mips*)   AG_ARCH="mips" ;;
    *)       fail "Unsupported architecture: $ARCH" ;;
esac

# Detect OS
AG_PLATFORM="linux"

# Check if already installed
if [ -x /opt/AdGuardHome/AdGuardHome ]; then
    INSTALLED_VERSION="$(/opt/AdGuardHome/AdGuardHome --version 2>/dev/null | head -1 || true)"
    msg "AdGuard Home already installed: ${INSTALLED_VERSION:-unknown}"
    msg "Updating..."
fi

msg "Fetching latest AdGuard Home release..."
RELEASE_JSON="$(http_get "${GITHUB_API}/repos/AdguardTeam/AdGuardHome/releases/latest")" \
    || fail "Failed to fetch release info from GitHub"

[ -n "$RELEASE_JSON" ] || fail "Empty response from GitHub API"

# Find matching asset
DOWNLOAD_URL="$(printf '%s\n' "$RELEASE_JSON" | grep -o "\"browser_download_url\":\"[^\"]*_${AG_PLATFORM}_${AG_ARCH}.tar.gz\"" | head -1 | sed 's/"browser_download_url":"//;s/"//')"

[ -n "$DOWNLOAD_URL" ] || fail "No AdGuard package found for ${AG_PLATFORM}/${AG_ARCH}"

msg "Downloading AdGuard Home..."
http_download "$DOWNLOAD_URL" "$TMP_DIR/adguard.tar.gz" || fail "Download failed"
[ -s "$TMP_DIR/adguard.tar.gz" ] || fail "Downloaded file is empty"

# Stop existing service if running
if [ -x /opt/AdGuardHome/AdGuardHome ]; then
    msg "Stopping existing AdGuard Home..."
    /opt/AdGuardHome/AdGuardHome -s stop 2>/dev/null || true
fi

# Extract
msg "Extracting..."
mkdir -p /opt/AdGuardHome
tar -xzf "$TMP_DIR/adguard.tar.gz" -C /opt/ 2>/dev/null \
    || tar -xzf "$TMP_DIR/adguard.tar.gz" --strip-components=1 -C /opt/AdGuardHome 2>/dev/null \
    || fail "Failed to extract AdGuard Home"

chmod +x /opt/AdGuardHome/AdGuardHome 2>/dev/null || true

# Install as service
msg "Installing AdGuard Home service..."
/opt/AdGuardHome/AdGuardHome -s install 2>/dev/null || true
/opt/AdGuardHome/AdGuardHome -s start 2>/dev/null || true

# Configure K.R.O.T. DNS to use AdGuard if needed
if command -v uci >/dev/null 2>&1; then
    # Check if K.R.O.T. DNS is set to default
    CURRENT_DNS="$(uci -q get krot.settings.dns_server 2>/dev/null || true)"
    if [ -z "$CURRENT_DNS" ] || [ "$CURRENT_DNS" = "8.8.8.8" ]; then
        msg "Tip: You can configure K.R.O.T. DNS to use AdGuard (127.0.0.1)"
        msg "      Go to Settings → DNS Server → enter 127.0.0.1"
    fi
fi

# Get router IP
ROUTER_IP="$(uci get network.lan.ipaddr 2>/dev/null || echo '192.168.1.1')"

msg "AdGuard Home installed successfully"
msg ""
msg "Web interface: http://${ROUTER_IP}:3000"
msg "DNS server:    ${ROUTER_IP}:53"
msg ""
msg "Next steps:"
msg "1. Open http://${ROUTER_IP}:3000 and complete setup wizard"
msg "2. Add blocklists in Filters → DNS blocklists"
msg "3. Optional: Set K.R.O.T. DNS Server to 127.0.0.1 in Settings"
