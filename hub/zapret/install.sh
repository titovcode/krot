#!/bin/sh
# Zapret standalone installer for K.R.O.T. Hub
# Source: https://github.com/remittor/zapret-openwrt
set -e

GITHUB_API="https://api.github.com"
TMP_DIR="$(mktemp -d /tmp/hub-zapret.XXXXXX 2>/dev/null || { mkdir -p /tmp/hub-zapret.$$; echo /tmp/hub-zapret.$$; })"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM

fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }
msg()  { printf '\033[32m%s\033[0m\n' "$1"; }

# Detect package format
PKG_IS_APK=0
command -v apk >/dev/null 2>&1 && PKG_IS_APK=1

# Get architecture list
if [ "$PKG_IS_APK" -eq 1 ]; then
    ARCH_LIST="$(apk info --print-arch 2>/dev/null)"
    EXT="apk"
else
    ARCH_LIST="$(opkg print-architecture 2>/dev/null | awk '{print $2}' | grep -v '^all$' | tr '\n' ' ')"
    EXT="ipk"
fi

[ -n "$ARCH_LIST" ] || fail "Could not detect architecture"

# Detect proxy from K.R.O.T. settings
PROXY_ADDR=""
if command -v uci >/dev/null 2>&1 && [ -f /etc/config/krot ]; then
    if uci -q get krot.settings.download_lists_via_proxy 2>/dev/null | grep -q '1'; then
        PROXY_ADDR="http://127.0.0.1:4534"
    fi
fi

# Download helper with proxy support (prefer curl over busybox wget for proxy)
http_get() {
    if [ -n "$PROXY_ADDR" ] && command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 30 -x "$PROXY_ADDR" "$1"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 30 "$1"
    elif [ -n "$PROXY_ADDR" ] && command -v wget >/dev/null 2>&1; then
        http_proxy="$PROXY_ADDR" https_proxy="$PROXY_ADDR" wget -qO- --timeout=30 "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout=30 "$1"
    else
        fail "wget or curl is required"
    fi
}

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

msg "Fetching latest Zapret release..."
RELEASE_JSON="$(http_get "${GITHUB_API}/repos/remittor/zapret-openwrt/releases/latest")" \
    || fail "Failed to fetch release info from GitHub"

[ -n "$RELEASE_JSON" ] || fail "Empty response from GitHub API"

# Find matching asset by arch
BUNDLE_URL=""
BUNDLE_NAME=""

for arch in $ARCH_LIST; do
    name="$(printf '%s\n' "$RELEASE_JSON" | grep -o "\"name\":\"[^\"]*_${arch}\\.zip\"" | head -1 | sed 's/"name":"//;s/"//')"
    if [ -n "$name" ]; then
        url="$(printf '%s\n' "$RELEASE_JSON" | grep -o "\"browser_download_url\":\"[^\"]*$(printf '%s' "$name" | sed 's/\./\\./g')\"" | head -1 | sed 's/"browser_download_url":"//;s/"//')"
        if [ -n "$url" ]; then
            BUNDLE_NAME="$name"
            BUNDLE_URL="$url"
            break
        fi
    fi
done

[ -n "$BUNDLE_URL" ] || fail "No Zapret package found for this architecture (${ARCH_LIST})"

msg "Downloading ${BUNDLE_NAME}..."
http_download "$BUNDLE_URL" "$TMP_DIR/bundle.zip" || fail "Download failed"
[ -s "$TMP_DIR/bundle.zip" ] || fail "Downloaded file is empty"

# Install unzip if needed
if ! command -v unzip >/dev/null 2>&1; then
    msg "Installing unzip..."
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add unzip || fail "Failed to install unzip"
    else
        opkg update >/dev/null 2>&1 && opkg install unzip || fail "Failed to install unzip"
    fi
fi

# Find package inside the zip
if [ "$PKG_IS_APK" -eq 1 ]; then
    PKG_PATH="$(unzip -l "$TMP_DIR/bundle.zip" | awk '{print $4}' | grep -E '^apk/zapret-.*\.apk$' | head -1)"
else
    for arch in $ARCH_LIST; do
        PKG_PATH="$(unzip -l "$TMP_DIR/bundle.zip" | awk '{print $4}' | grep -E "^zapret_.*_${arch}\.ipk$" | head -1)"
        [ -n "$PKG_PATH" ] && break
    done
    [ -n "$PKG_PATH" ] || PKG_PATH="$(unzip -l "$TMP_DIR/bundle.zip" | awk '{print $4}' | grep -E '^zapret_.*\.ipk$' | head -1)"
fi

[ -n "$PKG_PATH" ] || fail "Package not found inside bundle"

PKG_FILE="$TMP_DIR/$(basename "$PKG_PATH")"
unzip -p "$TMP_DIR/bundle.zip" "$PKG_PATH" > "$PKG_FILE" || fail "Extraction failed"
[ -s "$PKG_FILE" ] || fail "Extracted package is empty"

msg "Installing $(basename "$PKG_FILE")..."
if [ "$PKG_IS_APK" -eq 1 ]; then
    apk add --allow-untrusted "$PKG_FILE" || fail "Installation failed"
else
    opkg install --force-overwrite --force-downgrade "$PKG_FILE" || fail "Installation failed"
fi

# Post-install: disable standalone zapret service to avoid conflict with K.R.O.T.
if [ -x /etc/init.d/zapret ]; then
    msg "Stopping standalone zapret service..."
    /etc/init.d/zapret stop 2>/dev/null || true
    /etc/init.d/zapret disable 2>/dev/null || true
fi

# Restart K.R.O.T. to apply nfqueue integration
if [ -x /etc/init.d/krot ]; then
    msg "Restarting K.R.O.T..."
    /etc/init.d/krot reload 2>/dev/null || true
fi

msg "Zapret installed successfully"
