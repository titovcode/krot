#!/bin/sh
# Template module installer for K.R.O.T. Hub
# Copy this file and adapt it for your module.
set -e

TMP_DIR="$(mktemp -d /tmp/hub-_template.XXXXXX 2>/dev/null || { mkdir -p /tmp/hub-_template.$$; echo /tmp/hub-_template.$$; })"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM

fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }
msg()  { printf '\033[32m%s\033[0m\n' "$1"; }

# ── Configuration ──────────────────────────────────────────────────────
# Change these for your module:
MODULE_ID="_template"
MODULE_NAME="Template"
BIN_PATH="/usr/bin/_template"
CONFIG_DIR="/etc/_template"
VERSION_FILE="$CONFIG_DIR/VERSION"

# Proxy support for downloads
PROXY_ADDR=""
if command -v uci >/dev/null 2>&1 && [ -f /etc/config/krot ]; then
    if uci -q get krot.settings.download_lists_via_proxy 2>/dev/null | grep -q '1'; then
        PROXY_ADDR="http://127.0.0.1:4534"
    fi
fi

http_download() {
    if [ -n "$PROXY_ADDR" ] && command -v curl >/dev/null 2>&1; then
        curl -fSL --connect-timeout 15 --max-time 300 -x "$PROXY_ADDR" "$1" -o "$2"
    elif command -v curl >/dev/null 2>&1; then
        curl -fSL --connect-timeout 15 --max-time 300 "$1" -o "$2"
    elif [ -n "$PROXY_ADDR" ] && command -v wget >/dev/null 2>&1; then
        http_proxy="$PROXY_ADDR" https_proxy="$PROXY_ADDR" wget -qO "$2" --timeout=300 "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$2" --timeout=300 "$1"
    else
        fail "wget or curl is required"
    fi
}

# ── 1. Install binary ──────────────────────────────────────────────────
install_binary() {
    # Option A: Download from GitHub releases
    # msg "Downloading $MODULE_NAME..."
    # http_download "https://github.com/you/repo/releases/download/v1.0.0/binary" "$TMP_DIR/binary"
    # cp "$TMP_DIR/binary" "$BIN_PATH"
    
    # Option B: Copy from module files
    # cp "files/usr/bin/_template" "$BIN_PATH"
    
    # Option C: Install via opkg/apk
    # opkg update && opkg install your-package
    
    # For this template, we just create a placeholder
    msg "Installing $MODULE_NAME binary (placeholder)..."
    mkdir -p "$(dirname "$BIN_PATH")"
    echo '#!/bin/sh
echo "Template module v1.0.0"' > "$BIN_PATH"
    chmod 0755 "$BIN_PATH"
    
    # Record version for Hub detection
    mkdir -p "$CONFIG_DIR"
    echo "1.0.0" > "$VERSION_FILE"
    
    msg "Installed $MODULE_NAME v1.0.0"
}

install_binary

# ── 2. Install service ─────────────────────────────────────────────────
msg "Installing service..."

mkdir -p /etc/init.d /etc/config "$CONFIG_DIR/conf.d"

# Install init script
if [ -f "files/etc/init.d/$MODULE_ID" ]; then
    cp "files/etc/init.d/$MODULE_ID" "/etc/init.d/$MODULE_ID"
elif [ -f "$(dirname "$0")/files/etc/init.d/$MODULE_ID" ]; then
    cp "$(dirname "$0")/files/etc/init.d/$MODULE_ID" "/etc/init.d/$MODULE_ID"
else
    # Create a simple init script
    cat > "/etc/init.d/$MODULE_ID" << 'INITEOF'
#!/bin/sh /etc/rc.common
START=99
STOP=10

start() {
    echo "Starting _template..."
    # Add your start command here
    # /usr/bin/_template -c /etc/_template/config.json &
}

stop() {
    echo "Stopping _template..."
    # Add your stop command here
    # killall _template
}
INITEOF
fi
chmod 0755 "/etc/init.d/$MODULE_ID"

# Install UCI config if not present
if [ ! -f "/etc/config/$MODULE_ID" ]; then
    if [ -f "files/etc/config/$MODULE_ID" ]; then
        cp "files/etc/config/$MODULE_ID" "/etc/config/$MODULE_ID"
    elif [ -f "$(dirname "$0")/files/etc/config/$MODULE_ID" ]; then
        cp "$(dirname "$0")/files/etc/config/$MODULE_ID" "/etc/config/$MODULE_ID"
    else
        cat > "/etc/config/$MODULE_ID" << 'UCIEOF'
config _template 'config'
    option enabled '1'
UCIEOF
    fi
    chmod 0644 "/etc/config/$MODULE_ID"
fi

# ── 3. Enable and start ────────────────────────────────────────────────
/etc/init.d/$MODULE_ID enable 2>/dev/null || true
/etc/init.d/$MODULE_ID start 2>/dev/null || true

msg ""
msg "$MODULE_NAME installed successfully!"
msg "Config directory:  $CONFIG_DIR"
msg "Rule fragments:    $CONFIG_DIR/conf.d/<rule>.json"
msg ""
