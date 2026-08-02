#!/bin/sh
# olcRTC tunnel updater for K.R.O.T. Hub
# Re-downloads the binary and static assets; preserves /etc/config/olcrtc.
set -e

TMP_DIR="$(mktemp -d /tmp/hub-olcrtc.XXXXXX 2>/dev/null || { mkdir -p /tmp/hub-olcrtc.$$; echo /tmp/hub-olcrtc.$$; })"
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

REPO="${OLCRTC_REPO:-$(uci -q get krot.hub_source_olcrtc.repo 2>/dev/null || true)}"
REPO="${REPO:-${PODKOP_RELEASE_REPO:-titovcode/krot}}"
BRANCH="${OLCRTC_BRANCH:-$(uci -q get krot.hub_source_olcrtc.branch 2>/dev/null || true)}"
BRANCH="${BRANCH:-main}"

case "$(uname -m)" in
    x86_64)  OLC_ARCH="amd64" ;;
    aarch64) OLC_ARCH="arm64" ;;
    *)       fail "Unsupported architecture" ;;
esac

msg "Downloading olcrtc ($OLC_ARCH) from ${REPO} releases..."
if [ -n "$OLCRTC_BINARY_URL" ]; then
    DOWNLOAD_URL="$OLCRTC_BINARY_URL"
else
    OLCRTC_TAG="${OLCRTC_TAG:-olcrtc-0.1.0}"
    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${OLCRTC_TAG}/olcrtc-linux-${OLC_ARCH}"
fi
http_download "$DOWNLOAD_URL" "$TMP_DIR/olcrtc" || fail "Failed to download olcrtc"
[ -s "$TMP_DIR/olcrtc" ] || fail "Downloaded binary is empty"
mkdir -p /opt/olcrtc
cp "$TMP_DIR/olcrtc" /opt/olcrtc/olcrtc && chmod 0755 /opt/olcrtc/olcrtc

msg "Updating QR renderer..."
http_download "https://raw.githubusercontent.com/${REPO}/${BRANCH}/hub/olcrtc/qrcode.js" \
    /www/olcrtc/qrcode.js || true

# Route phone tunnel traffic through K.R.O.T.'s mixed inbound (sing-box) so
# routing rules apply to phone traffic. Only fills the socks proxy when the
# user hasn't configured one explicitly.
if command -v uci >/dev/null 2>&1 && [ -f /etc/config/olcrtc ]; then
    if [ -z "$(uci -q get olcrtc.settings.socks_proxy_addr 2>/dev/null || true)" ] \
        && [ -z "$(uci -q get olcrtc.settings.socks_proxy_port 2>/dev/null || true)" ]; then
        lan_ip="$(uci -q get network.lan.ipaddr 2>/dev/null || echo '192.168.1.1')"
        mp_port=""
        for sec in $(uci -q show krot 2>/dev/null | sed -n 's/^krot\.\([^.]*\)=section$/\1/p'); do
            [ "$(uci -q get "krot.${sec}.mixed_proxy_enabled" 2>/dev/null || echo 0)" = "1" ] || continue
            mp_port="$(uci -q get "krot.${sec}.mixed_proxy_port" 2>/dev/null || true)"
            [ -n "$mp_port" ] && break
        done
        if [ -n "$mp_port" ]; then
            uci -q set "olcrtc.settings.socks_proxy_addr=${lan_ip}"
            uci -q set "olcrtc.settings.socks_proxy_port=${mp_port}"
            uci -q commit olcrtc 2>/dev/null || true
        fi
    fi
fi

[ -x /opt/olcrtc/gen-qr.sh ] && /opt/olcrtc/gen-qr.sh >/dev/null 2>&1 || true

/etc/init.d/olcrtc restart 2>/dev/null || true

msg "olcrtc updated"
