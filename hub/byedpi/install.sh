#!/bin/sh
# ByeDPI standalone installer for K.R.O.T. Hub
# Source: https://github.com/DPITrickster/ByeDPI-OpenWrt
set -e

GITHUB_API="https://api.github.com"
TMP_DIR="$(mktemp -d /tmp/hub-byedpi.XXXXXX 2>/dev/null || { mkdir -p /tmp/hub-byedpi.$$; echo /tmp/hub-byedpi.$$; })"

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

# Get OpenWrt release series (e.g. "24.10")
OPENWRT_RELEASE=""
if [ -f /etc/openwrt_release ]; then
    OPENWRT_RELEASE="$(grep 'DISTRIB_RELEASE' /etc/openwrt_release | cut -d'"' -f2 | grep -oE '^[0-9]+\.[0-9]+')"
fi

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

msg "Fetching ByeDPI releases..."
RELEASES_JSON="$(http_get "${GITHUB_API}/repos/DPITrickster/ByeDPI-OpenWrt/releases?per_page=30")" \
    || fail "Failed to fetch release info from GitHub"

[ -n "$RELEASES_JSON" ] || fail "Empty response from GitHub API"

# Find matching asset: prefer release matching OPENWRT_RELEASE, then any
find_asset() {
    local series="$1"
    local pattern
    for arch in $ARCH_LIST; do
        if [ -n "$series" ]; then
            pattern="ciadpi_.*_${series}_.*_${arch}\\.${EXT}"
        else
            pattern="ciadpi_.*_${arch}\\.${EXT}"
        fi
        name="$(printf '%s\n' "$RELEASES_JSON" | grep -o "\"name\":\"[^\"]*\"" | sed 's/"name":"//;s/"//' | grep -E "$pattern" | head -1)"
        if [ -n "$name" ]; then
            url="$(printf '%s\n' "$RELEASES_JSON" | grep -o "\"browser_download_url\":\"[^\"]*$(printf '%s' "$name" | sed 's/\./\\./g')\"" | head -1 | sed 's/"browser_download_url":"//;s/"//')"
            if [ -n "$url" ]; then
                printf '%s\t%s\n' "$name" "$url"
                return 0
            fi
        fi
    done
    return 1
}

RESULT=""
[ -n "$OPENWRT_RELEASE" ] && RESULT="$(find_asset "$OPENWRT_RELEASE" 2>/dev/null || true)"
[ -n "$RESULT" ] || RESULT="$(find_asset "" 2>/dev/null || true)"

[ -n "$RESULT" ] || fail "No ByeDPI package found for this architecture (${ARCH_LIST})"

PKG_NAME="$(printf '%s\n' "$RESULT" | cut -f1)"
PKG_URL="$(printf '%s\n' "$RESULT" | cut -f2)"

msg "Downloading ${PKG_NAME}..."
http_download "$PKG_URL" "$TMP_DIR/$PKG_NAME" || fail "Download failed"
[ -s "$TMP_DIR/$PKG_NAME" ] || fail "Downloaded file is empty"

msg "Installing ${PKG_NAME}..."
if [ "$PKG_IS_APK" -eq 1 ]; then
    apk add --allow-untrusted "$TMP_DIR/$PKG_NAME" || fail "Installation failed"
else
    opkg install --force-overwrite --force-downgrade "$TMP_DIR/$PKG_NAME" || fail "Installation failed"
fi

# Post-install: disable standalone byedpi service to avoid conflict with K.R.O.T.
if [ -x /etc/init.d/byedpi ]; then
    msg "Stopping standalone byedpi service..."
    /etc/init.d/byedpi stop 2>/dev/null || true
    /etc/init.d/byedpi disable 2>/dev/null || true
fi

# Restart K.R.O.T. to apply integration
if [ -x /etc/init.d/krot ]; then
    msg "Restarting K.R.O.T..."
    /etc/init.d/krot reload 2>/dev/null || true
fi

msg "ByeDPI installed successfully"
