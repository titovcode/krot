#!/bin/sh
# Xray-core installer for K.R.O.T. Hub
set -e

TMP_DIR="$(mktemp -d /tmp/hub-xray.XXXXXX 2>/dev/null || { mkdir -p /tmp/hub-xray.$$; echo /tmp/hub-xray.$$; })"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM

fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }
msg()  { printf '\033[32m%s\033[0m\n' "$1"; }

PROXY_ADDR=""
if command -v uci >/dev/null 2>&1 && [ -f /etc/config/krot ]; then
    if uci -q get krot.settings.download_lists_via_proxy 2>/dev/null | grep -q '1'; then
        PROXY_ADDR="http://127.0.0.1:4534"
    fi
fi

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

REPO="${XRAY_REPO:-$(uci -q get krot.hub_source_xray.repo 2>/dev/null || true)}"
REPO="${REPO:-${PODKOP_RELEASE_REPO:-titovcode/krot}}"
BRANCH="${XRAY_BRANCH:-$(uci -q get krot.hub_source_xray.branch 2>/dev/null || true)}"
BRANCH="${BRANCH:-main}"

RAW_BASE="https://raw.githubusercontent.com/${REPO}/${BRANCH}/hub/xray"

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)           XRAY_ARCH="64" ;;
    i386|i686)        XRAY_ARCH="32" ;;
    aarch64|arm64)    XRAY_ARCH="arm64-v8a" ;;
    armv7*|armhf)     XRAY_ARCH="arm32-v7a" ;;
    armv6*)           XRAY_ARCH="arm32-v6" ;;
    armv5*)           XRAY_ARCH="arm32-v5" ;;
    mips64el)         XRAY_ARCH="mips64le" ;;
    mips64)           XRAY_ARCH="mips64" ;;
    mipsel*)          XRAY_ARCH="mips32le" ;;
    mips*)            XRAY_ARCH="mips32" ;;
    riscv64)          XRAY_ARCH="riscv64" ;;
    *)                fail "Unsupported architecture: $ARCH" ;;
esac


# ── 1. Install binary ──────────────────────────────────────────────────
install_binary() {
    if [ -x /usr/bin/xray ]; then
        msg "Xray binary already present at /usr/bin/xray"
        return 0
    fi
    if [ -f /tmp/xray ]; then
        msg "Installing manually placed binary from /tmp/xray..."
        cp /tmp/xray /usr/bin/xray && chmod 0755 /usr/bin/xray
        return 0
    fi

    msg "Fetching latest Xray-core release info..."
    local release_json
    release_json="$(http_get "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null || true)"
    local tag_name=""
    if [ -n "$release_json" ]; then
        tag_name="$(printf '%s\n' "$release_json" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//;s/"$//')"
    fi
    tag_name="${tag_name:-v26.3.27}"

    local download_url="https://github.com/XTLS/Xray-core/releases/download/${tag_name}/Xray-linux-${XRAY_ARCH}.zip"
    msg "Downloading Xray-core (${tag_name}, ${XRAY_ARCH})..."
    
    if http_download "$download_url" "$TMP_DIR/xray.zip" 2>/dev/null && [ -s "$TMP_DIR/xray.zip" ]; then
        if command -v unzip >/dev/null 2>&1; then
            unzip -q -o "$TMP_DIR/xray.zip" xray -d "$TMP_DIR" 2>/dev/null || unzip -q -o "$TMP_DIR/xray.zip" -d "$TMP_DIR"
            if [ -f "$TMP_DIR/xray" ]; then
                cp "$TMP_DIR/xray" /usr/bin/xray
                chmod 0755 /usr/bin/xray
                mkdir -p /etc/xray
                echo "${tag_name#v}" > /etc/xray/VERSION
                msg "Installed Xray-core from official release (${tag_name})"
                return 0
            fi
        fi
    fi

    # Fallback to opkg if download or unzip failed
    if command -v opkg >/dev/null 2>&1; then
        msg "Attempting opkg install xray-core..."
        opkg update >/dev/null 2>&1 || true
        if opkg install xray-core; then
            local ver
            ver="$(opkg list-installed xray-core 2>/dev/null | awk '{print $3}')"
            mkdir -p /etc/xray
            [ -n "$ver" ] && echo "$ver" > /etc/xray/VERSION
            msg "Installed xray-core via opkg"
            return 0
        fi
    fi

    fail "Failed to install Xray-core binary"
}

install_binary

# ── 2. Service & Configuration ─────────────────────────────────────────
mkdir -p /etc/xray /etc/config /etc/init.d

if [ -f "files/etc/init.d/xray" ]; then
    cp "files/etc/init.d/xray" /etc/init.d/xray
elif [ -f "$(dirname "$0")/files/etc/init.d/xray" ]; then
    cp "$(dirname "$0")/files/etc/init.d/xray" /etc/init.d/xray
else
    http_download "${RAW_BASE}/files/etc/init.d/xray" /etc/init.d/xray || fail "Failed to download init script"
fi
chmod 0755 /etc/init.d/xray

if [ ! -f /etc/config/xray ]; then
    if [ -f "files/etc/config/xray" ]; then
        cp "files/etc/config/xray" /etc/config/xray
    elif [ -f "$(dirname "$0")/files/etc/config/xray" ]; then
        cp "$(dirname "$0")/files/etc/config/xray" /etc/config/xray
    else
        http_download "${RAW_BASE}/files/etc/config/xray" /etc/config/xray || fail "Failed to download UCI config"
    fi
    chmod 0644 /etc/config/xray
fi

if [ ! -f /etc/xray/config.json ]; then
    if [ -f "files/etc/xray/config.json.sample" ]; then
        cp "files/etc/xray/config.json.sample" /etc/xray/config.json
    elif [ -f "$(dirname "$0")/files/etc/xray/config.json.sample" ]; then
        cp "$(dirname "$0")/files/etc/xray/config.json.sample" /etc/xray/config.json
    else
        http_download "${RAW_BASE}/files/etc/xray/config.json.sample" /etc/xray/config.json || true
    fi
    chmod 0644 /etc/xray/config.json
fi

if [ -x /usr/bin/xray ] && [ ! -f /etc/xray/VERSION ]; then
    VER="$(/usr/bin/xray version 2>/dev/null | head -1 | awk '{print $2}')"
    [ -n "$VER" ] && echo "$VER" > /etc/xray/VERSION
fi

# ── 3. Enable and Start ────────────────────────────────────────────────
/etc/init.d/xray enable 2>/dev/null || true
/etc/init.d/xray restart 2>/dev/null || /etc/init.d/xray start 2>/dev/null || true

msg ""
msg "Xray-core sidecar installed successfully!"
msg "Config file: /etc/xray/config.json"
msg "Default SOCKS5 inbound: 127.0.0.1:10808"
msg "Default HTTP inbound:   127.0.0.1:10809"
msg ""
msg "In K.R.O.T. Web UI, create an outbound section with:"
msg "  Action: JSON outbound"
msg "  Outbound JSON:"
msg "  {\"type\":\"socks\",\"server\":\"127.0.0.1\",\"server_port\":10808,\"version\":\"5\"}"
msg ""
