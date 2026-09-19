#!/bin/sh
# OpenFlux Exit Node installer for K.R.O.T. Hub
# Upstream: https://github.com/p1neappleXpress/OpenFlux
# Setup guide: https://github.com/p1neappleXpress/OpenFlux/issues/44
#
# What it does:
#   1. Installs the module payload (procd service, runner, LuCI page, ACL).
#   2. Installs the openflux binary for the router architecture.
#   3. Installs firewall helpers that keep the Linux kernel from RST-ing the
#      tunnel connections in l3 mode (see issue #44 "kernel RST" section).
#   4. Enables the krot-openflux service.
#
# Environment overrides (testing / forks / custom builds):
#   OF_REPO=titovcode/krot       GitHub repo with the module payload
#   OF_BRANCH=main               Branch with the module payload
#   OF_PAYLOAD_DIR=./files       Local dir with payload files (skip downloading)
#   OF_BIN_BASE=https://...      Base URL with openflux-linux-<arch> files
#                                (empty = OF_RELEASE_REPO releases, else none)
#   OF_RELEASE_REPO=p1neappleXpress/OpenFlux
#                                Upstream releases to look for binaries in
#   OF_IPTABLES=1                Force iptables RST suppression instead of nft
set -e

MODULE_ID="openflux"
MODULE_VERSION="0.1.0"
OF_REPO="${OF_REPO:-titovcode/krot}"
OF_BRANCH="${OF_BRANCH:-main}"
OF_PAYLOAD_DIR="${OF_PAYLOAD_DIR:-}"
OF_BIN_BASE="${OF_BIN_BASE:-}"
OF_RELEASE_REPO="${OF_RELEASE_REPO:-p1neappleXpress/OpenFlux}"

RAW_BASE="https://raw.githubusercontent.com/${OF_REPO}/${OF_BRANCH}/hub/${MODULE_ID}/files"
GITHUB_API="https://api.github.com"

LIB_DIR="/usr/lib/krot-openflux"
STATE_DIR="/etc/krot-openflux"
RUN_DIR="/var/run/krot-openflux"
NFT_CHAIN="krot_openflux_rst"
IPT_CHAIN="KROT_OPENFLUX"
TMP_DIR="$(mktemp -d /tmp/hub-openflux.XXXXXX 2>/dev/null || { mkdir -p /tmp/hub-openflux.$$; echo /tmp/hub-openflux.$$; })"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM

fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }
msg()  { printf '\033[32m%s\033[0m\n' "$1"; }
warn() { printf '\033[33m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
# Download helpers (same conventions as other K.R.O.T. Hub modules)
# ---------------------------------------------------------------------------

# Reuse the K.R.O.T. proxy for downloads when the user enabled it.
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
        curl -fSL --connect-timeout 15 --max-time 600 -x "$PROXY_ADDR" "$1" -o "$2"
    elif command -v curl >/dev/null 2>&1; then
        curl -fSL --connect-timeout 15 --max-time 600 "$1" -o "$2"
    elif [ -n "$PROXY_ADDR" ] && command -v wget >/dev/null 2>&1; then
        http_proxy="$PROXY_ADDR" https_proxy="$PROXY_ADDR" wget -qO "$2" --timeout=600 "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$2" --timeout=600 "$1"
    else
        fail "wget or curl is required"
    fi
}

# ---------------------------------------------------------------------------
# Payload: service, runner, LuCI page, ACL
# ---------------------------------------------------------------------------

# src(relative to files/) | dest(absolute) | mode
PAYLOAD_FILES="
etc/init.d/krot-openflux|/etc/init.d/krot-openflux|0755
etc/config/krot_openflux|/etc/config/krot_openflux|0644
usr/lib/krot-openflux/openflux-run.sh|/usr/lib/krot-openflux/openflux-run.sh|0755
usr/share/rpcd/acl.d/krot-openflux.json|/usr/share/rpcd/acl.d/krot-openflux.json|0644
usr/share/luci/menu.d/krot-openflux.json|/usr/share/luci/menu.d/krot-openflux.json|0644
www/luci-static/resources/view/krot-openflux/openflux.js|/www/luci-static/resources/view/krot-openflux/openflux.js|0644
"

install_payload() {
    msg "Installing module payload..."
    local entry src dest mode
    for entry in $PAYLOAD_FILES; do
        src="${entry%%|*}"
        entry="${entry#*|}"
        dest="${entry%%|*}"
        mode="${entry#*|}"

        # Never clobber an existing user config.
        if [ "$dest" = "/etc/config/krot_openflux" ] && [ -f "$dest" ]; then
            continue
        fi

        mkdir -p "$(dirname "$dest")" || fail "Failed to create $(dirname "$dest")"
        if [ -n "$OF_PAYLOAD_DIR" ]; then
            [ -f "${OF_PAYLOAD_DIR}/${src}" ] || fail "Payload file missing: ${OF_PAYLOAD_DIR}/${src}"
            cp "${OF_PAYLOAD_DIR}/${src}" "$dest" || fail "Failed to copy ${src}"
        else
            http_download "${RAW_BASE}/${src}" "$dest" || fail "Failed to download ${RAW_BASE}/${src}"
        fi
        chmod "$mode" "$dest"
    done

    mkdir -p "$LIB_DIR/bin" "$STATE_DIR" "$RUN_DIR"
    echo "$MODULE_VERSION" > "${LIB_DIR}/VERSION"
}

# ---------------------------------------------------------------------------
# Binary
# ---------------------------------------------------------------------------

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)              BIN_LABEL="amd64" ;;
    aarch64|arm64)       BIN_LABEL="arm64" ;;
    armv7l|armv7)        BIN_LABEL="armv7" ;;
    armv6l|armv6)        BIN_LABEL="armv6" ;;
    mipsel)              BIN_LABEL="mipsle" ;;
    mips)                BIN_LABEL="mips" ;;
    mips64el)            BIN_LABEL="mips64le" ;;
    *) fail "Unsupported architecture: $ARCH (openflux is a Go binary; build it with hub/${MODULE_ID}/build-binaries.sh for this arch)" ;;
esac

install_binary() {
    local url base ok=0

    # Already there (reinstall / update)?
    if [ -x "${LIB_DIR}/bin/openflux" ]; then
        msg "openflux binary already present in ${LIB_DIR}/bin, skipping download"
        return 0
    fi

    # Path 1: custom OF_BIN_BASE, or the upstream release assets when available.
    if [ -n "$OF_BIN_BASE" ]; then
        base="${OF_BIN_BASE%/}"
    else
        base="https://github.com/${OF_RELEASE_REPO}/releases/latest/download"
    fi
    url="${base}/openflux-linux-${BIN_LABEL}"
    msg "Architecture: $ARCH (label: $BIN_LABEL)"
    msg "Trying ${url} ..."
    if http_download "$url" "$TMP_DIR/openflux" 2>/dev/null && [ -s "$TMP_DIR/openflux" ]; then
        # Sanity: an ELF, not an HTML error page.
        if [ "$(head -c 4 "$TMP_DIR/openflux" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; then
            mv "$TMP_DIR/openflux" "${LIB_DIR}/bin/openflux"
            chmod 0755 "${LIB_DIR}/bin/openflux"
            msg "installed openflux (direct asset)"
            ok=1
        else
            rm -f "$TMP_DIR/openflux"
        fi
    fi
    [ "$ok" -eq 1 ] && return 0

    # Path 2: scan upstream releases for a matching asset name.
    if [ -z "$OF_BIN_BASE" ]; then
        msg "Fetching ${OF_RELEASE_REPO} releases..."
        local release_json asset_url
        release_json="$(http_get "${GITHUB_API}/repos/${OF_RELEASE_REPO}/releases?per_page=20")" \
            || warn "Failed to fetch releases from GitHub"
        if [ -n "$release_json" ]; then
            asset_url="$(printf '%s\n' "$release_json" \
                | grep -o "\"browser_download_url\"[[:space:]]*:[[:space:]]*\"[^\"]*openflux-linux-${BIN_LABEL}\"" \
                | head -1 | sed 's/^"browser_download_url"[[:space:]]*:[[:space:]]*"//;s/"$//')"
            if [ -n "$asset_url" ]; then
                msg "Downloading $(basename "$asset_url")..."
                if http_download "$asset_url" "$TMP_DIR/openflux" && [ -s "$TMP_DIR/openflux" ]; then
                    if [ "$(head -c 4 "$TMP_DIR/openflux" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; then
                        mv "$TMP_DIR/openflux" "${LIB_DIR}/bin/openflux"
                        chmod 0755 "${LIB_DIR}/bin/openflux"
                        msg "installed openflux (from $(basename "$asset_url"))"
                        ok=1
                    fi
                fi
            fi
        fi
    fi
    [ "$ok" -eq 1 ] && return 0

    warn "No prebuilt openflux-linux-${BIN_LABEL} found."
    warn "Build it yourself: hub/${MODULE_ID}/build-binaries.sh (needs Go; cross-compiles to ./dist)"
    warn "then set option bin_base in /etc/config/krot_openflux to a URL serving openflux-linux-${BIN_LABEL}"
    warn "or copy the binary to ${LIB_DIR}/bin/openflux and press Restart on the module page."
    return 0
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

install_payload
install_binary

if [ -x /etc/init.d/krot-openflux ]; then
    /etc/init.d/krot-openflux enable >/dev/null 2>&1 || true
    /etc/init.d/krot-openflux restart >/dev/null 2>&1 || true
fi

# Make LuCI pick up the new menu entry and ACL.
/etc/init.d/rpcd restart >/dev/null 2>&1 || true

msg ""
msg "OpenFlux Exit Node installed successfully"
msg ""
msg "Next steps:"
msg "  1. Re-login to LuCI (ACL refresh), then open: Services -> OpenFlux"
msg "  2. Pick a transport, paste its URL/token, set the exit mode (l3 = Linux root, l4 = no root)"
msg "  3. If no binary was found, build one with hub/${MODULE_ID}/build-binaries.sh and set bin_base"
msg "  4. On the phone install OpenFluxAndroid and point it at this router"
msg ""
