#!/bin/sh
# Xray-core updater for K.R.O.T. Hub
# Preserves /etc/xray/config.json, /etc/config/xray and the per-rule Xray
# fragments that K.R.O.T. renders into /etc/xray/conf.d — the update only
# swaps the binary, it never deletes or regenerates rule configs.
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

# Keep the config layout the binary expects intact: /etc/xray/conf.d holds the
# per-rule Xray fragments rendered by K.R.O.T. — never remove or rewrite them
# here, only make sure the directory exists so the service can start.
mkdir -p /etc/xray/conf.d
mkdir -p /opt/xray

msg "Fetching latest Xray-core release info..."
release_json="$(http_get "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null || true)"
tag_name=""
if [ -n "$release_json" ]; then
    tag_name="$(printf '%s\n' "$release_json" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//;s/"$//')"
fi
tag_name="${tag_name:-v26.3.27}"

# A hardcoded fallback tag must never silently downgrade a newer install (this
# path exists precisely because GitHub may be unreachable).
current_version=""
[ -r /etc/xray/VERSION ] && current_version="$(cat /etc/xray/VERSION 2>/dev/null)"
if [ -n "${tag_name#v}" ] && [ -n "$current_version" ]; then
    newest="$(printf '%s\n' "${current_version#v}" "${tag_name#v}" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
    if [ "$newest" = "${current_version#v}" ] && [ "$current_version" != "${tag_name#v}" ]; then
        msg "Installed Xray-core $current_version is newer than the fallback tag; nothing to update"
        exit 0
    fi
fi

download_url="https://github.com/XTLS/Xray-core/releases/download/${tag_name}/Xray-linux-${XRAY_ARCH}.zip"
msg "Downloading Xray-core (${tag_name}, ${XRAY_ARCH})..."

if http_download "$download_url" "$TMP_DIR/xray.zip" 2>/dev/null && [ -s "$TMP_DIR/xray.zip" ]; then
    if command -v unzip >/dev/null 2>&1; then
        unzip -q -o "$TMP_DIR/xray.zip" xray -d "$TMP_DIR" 2>/dev/null || unzip -q -o "$TMP_DIR/xray.zip" -d "$TMP_DIR"
        if [ -f "$TMP_DIR/xray" ]; then
            chmod 0755 "$TMP_DIR/xray"
            # A new binary must pass its config parse before it goes live; a
            # broken download must never replace a working core.
            if ! "$TMP_DIR/xray" run -test -confdir /etc/xray >/dev/null 2>&1 &&
               ! "$TMP_DIR/xray" version >/dev/null 2>&1; then
                fail "Downloaded Xray binary is not runnable; aborting"
            fi
            # Replace via rename: `cp` onto the running binary fails with
            # ETXTBSY (Text file busy) while the service is up.
            backup=""
            if [ -f /usr/bin/xray ]; then
                backup="$TMP_DIR/xray.old"
                cp /usr/bin/xray "$backup"
            fi
            mv -f "$TMP_DIR/xray" /usr/bin/xray
            chmod 0755 /usr/bin/xray
            mkdir -p /etc/xray
            echo "${tag_name#v}" > /etc/xray/VERSION
            if ! /etc/init.d/xray restart 2>/dev/null; then
                if [ -n "$backup" ] && "$backup" version >/dev/null 2>&1; then
                    cp "$backup" /usr/bin/xray
                    chmod 0755 /usr/bin/xray
                    [ -n "$current_version" ] && echo "${current_version#v}" > /etc/xray/VERSION
                    /etc/init.d/xray restart 2>/dev/null || true
                fi
                fail "Xray failed to restart with the new binary; rolled back"
            fi
            msg "Xray-core updated to ${tag_name}"
            exit 0
        fi
    fi
fi

if command -v opkg >/dev/null 2>&1; then
    msg "Attempting opkg upgrade xray-core..."
    opkg update >/dev/null 2>&1 || true
    if opkg upgrade xray-core; then
        ver="$(opkg list-installed xray-core 2>/dev/null | awk '{print $3}')"
        mkdir -p /etc/xray
        [ -n "$ver" ] && echo "$ver" > /etc/xray/VERSION
        /etc/init.d/xray restart 2>/dev/null || true
        msg "Xray-core updated via opkg"
        exit 0
    fi
fi

fail "Failed to update Xray-core binary"
