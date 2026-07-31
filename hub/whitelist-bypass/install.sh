#!/bin/sh
# Whitelist Bypass installer for K.R.O.T. Hub
# Upstream: https://github.com/kulikov0/whitelist-bypass
#
# What it does:
#   1. Installs the module payload (procd service, runner, notifier, LuCI page).
#   2. Installs headless creator binaries for the router architecture.
#   3. Enables the krot-wlb service.
#
# Environment overrides (useful for testing / forks / custom builds):
#   WLB_REPO=titovcode/krot     GitHub repo with the module payload
#   WLB_BRANCH=main             Branch with the module payload
#   WLB_PAYLOAD_DIR=./files     Local dir with payload files (skip downloading them)
#   WLB_BIN_BASE=https://...    Base URL with headless-<platform>-creator-linux-<arch> files
#   WLB_PLATFORMS="telemost vk" Platforms to install (default: all four)
set -e

MODULE_ID="whitelist-bypass"
MODULE_VERSION="0.3.0"
WLB_REPO="${WLB_REPO:-titovcode/krot}"
WLB_BRANCH="${WLB_BRANCH:-main}"
WLB_PAYLOAD_DIR="${WLB_PAYLOAD_DIR:-}"
WLB_BIN_BASE="${WLB_BIN_BASE:-}"
WLB_PLATFORMS="${WLB_PLATFORMS:-telemost vk wbstream dion}"
UPSTREAM_REPO="kulikov0/whitelist-bypass"

RAW_BASE="https://raw.githubusercontent.com/${WLB_REPO}/${WLB_BRANCH}/hub/${MODULE_ID}/files"
GITHUB_API="https://api.github.com"

LIB_DIR="/usr/lib/krot-wlb"
BIN_DIR="${LIB_DIR}/bin"
STATE_DIR="/etc/krot-wlb"
TMP_DIR="$(mktemp -d /tmp/hub-wlb.XXXXXX 2>/dev/null || { mkdir -p /tmp/hub-wlb.$$; echo /tmp/hub-wlb.$$; })"

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
# Payload: service, runner, notifier, LuCI page
# ---------------------------------------------------------------------------

# src(relative to files/) | dest(absolute) | mode
PAYLOAD_FILES="
etc/init.d/krot-wlb|/etc/init.d/krot-wlb|0755
etc/config/krot_wlb|/etc/config/krot_wlb|0644
usr/lib/krot-wlb/wlb-run.sh|/usr/lib/krot-wlb/wlb-run.sh|0755
usr/lib/krot-wlb/wlb-notify.sh|/usr/lib/krot-wlb/wlb-notify.sh|0755
usr/lib/krot-wlb/wlb-yandex-login.sh|/usr/lib/krot-wlb/wlb-yandex-login.sh|0755
usr/share/rpcd/acl.d/krot-wlb.json|/usr/share/rpcd/acl.d/krot-wlb.json|0644
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
        if [ "$dest" = "/etc/config/krot_wlb" ] && [ -f "$dest" ]; then
            continue
        fi

        mkdir -p "$(dirname "$dest")" || fail "Failed to create $(dirname "$dest")"
        if [ -n "$WLB_PAYLOAD_DIR" ]; then
            [ -f "${WLB_PAYLOAD_DIR}/${src}" ] || fail "Payload file missing: ${WLB_PAYLOAD_DIR}/${src}"
            cp "${WLB_PAYLOAD_DIR}/${src}" "$dest" || fail "Failed to copy ${src}"
        else
            http_download "${RAW_BASE}/${src}" "$dest" || fail "Failed to download ${RAW_BASE}/${src}"
        fi
        chmod "$mode" "$dest"
    done

    mkdir -p "$BIN_DIR" "$STATE_DIR/state"
    echo "$MODULE_VERSION" > "${LIB_DIR}/VERSION"

    # Cleanup leftovers from the 0.2.x standalone LuCI page: management now
    # lives in K.R.O.T. -> Servers (protocol "Whitelist Bypass").
    rm -f /usr/share/luci/menu.d/krot-wlb.json
    rm -rf /www/luci-static/resources/view/krot-wlb
}

# ---------------------------------------------------------------------------
# Binaries
# ---------------------------------------------------------------------------

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)                BIN_LABEL="x64";     ZIP_FAMILY="x64";  ZIP_SUBDIR="" ;;
    i386|i486|i586|i686)   BIN_LABEL="ia32";    ZIP_FAMILY="ia32"; ZIP_SUBDIR="" ;;
    aarch64|arm64)         BIN_LABEL="arm64";   ZIP_FAMILY="arm";  ZIP_SUBDIR="arm64" ;;
    arm*)                  BIN_LABEL="arm";     ZIP_FAMILY="arm";  ZIP_SUBDIR="arm" ;;
    mipsel)                BIN_LABEL="mipsle";  ZIP_FAMILY="mips"; ZIP_SUBDIR="mipsle" ;;
    mips)                  BIN_LABEL="mips";    ZIP_FAMILY="mips"; ZIP_SUBDIR="mips" ;;
    mips64el)              BIN_LABEL="mips64le"; ZIP_FAMILY="mips"; ZIP_SUBDIR="mips64le" ;;
    mips64)                BIN_LABEL="mips64";  ZIP_FAMILY="mips"; ZIP_SUBDIR="mips64" ;;
    *) fail "Unsupported architecture: $ARCH" ;;
esac

bin_name() { echo "headless-$1-creator"; }

missing_platforms() {
    local p missing=""
    for p in $WLB_PLATFORMS; do
        [ -x "${BIN_DIR}/$(bin_name "$p")" ] || missing="$missing $p"
    done
    echo "${missing# }"
}

unzip_one() {
    # unzip_one <zip> <member> <dest>
    local zip="$1" member="$2" dest="$3"
    if command -v unzip >/dev/null 2>&1; then
        unzip -p "$zip" "$member" > "$dest" 2>/dev/null
    elif busybox unzip -h >/dev/null 2>&1; then
        busybox unzip -p "$zip" "$member" > "$dest" 2>/dev/null
    else
        return 1
    fi
}

install_binaries() {
    local missing p url ok
    missing="$(missing_platforms)"
    if [ -z "$missing" ]; then
        msg "Creator binaries already present in $BIN_DIR, skipping download"
        return 0
    fi

    msg "Architecture: $ARCH (label: $BIN_LABEL)"
    msg "Installing creators for:$missing"

    # Path 1: direct binary assets (custom WLB_BIN_BASE, or upstream x64/ia32 releases)
    local base="${WLB_BIN_BASE:-https://github.com/${UPSTREAM_REPO}/releases/latest/download}"
    ok=1
    for p in $missing; do
        url="${base}/$(bin_name "$p")-linux-${BIN_LABEL}"
        if http_download "$url" "$TMP_DIR/$(bin_name "$p")" 2>/dev/null && [ -s "$TMP_DIR/$(bin_name "$p")" ]; then
            # Sanity: an ELF, not an HTML error page.
            if [ "$(head -c 4 "$TMP_DIR/$(bin_name "$p")" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; then
                mv "$TMP_DIR/$(bin_name "$p")" "${BIN_DIR}/$(bin_name "$p")"
                chmod 0755 "${BIN_DIR}/$(bin_name "$p")"
                msg "  installed $(bin_name "$p") (direct asset)"
                continue
            fi
            rm -f "$TMP_DIR/$(bin_name "$p")"
        fi
        ok=0
    done
    [ "$ok" -eq 1 ] && return 0

    # Path 2: upstream CLI zip bundle for this CPU family (arm/mips live only there)
    missing="$(missing_platforms)"
    [ -z "$missing" ] && return 0

    msg "Fetching ${UPSTREAM_REPO} releases for the ${ZIP_FAMILY} CLI bundle..."
    local release_json zip_url
    release_json="$(http_get "${GITHUB_API}/repos/${UPSTREAM_REPO}/releases/latest")" \
        || fail "Failed to fetch release info from GitHub"
    zip_url="$(printf '%s\n' "$release_json" \
        | grep -o "\"browser_download_url\"[[:space:]]*:[[:space:]]*\"[^\"]*whitelist-bypass-cli-linux-${ZIP_FAMILY}\.zip\"" \
        | head -1 | sed 's/^"browser_download_url"[[:space:]]*:[[:space:]]*"//;s/"$//')"
    [ -n "$zip_url" ] || fail "No whitelist-bypass-cli-linux-${ZIP_FAMILY}.zip in the latest upstream release. Build binaries yourself with hub/${MODULE_ID}/build-binaries.sh and copy them into $BIN_DIR, then re-run install."

    msg "Downloading $(basename "$zip_url")..."
    http_download "$zip_url" "$TMP_DIR/cli.zip" || fail "Download failed"
    [ -s "$TMP_DIR/cli.zip" ] || fail "Downloaded file is empty"

    for p in $missing; do
        local member
        if [ -n "$ZIP_SUBDIR" ]; then
            member="${ZIP_SUBDIR}/$(bin_name "$p")"
        else
            member="$(bin_name "$p")"
        fi
        unzip_one "$TMP_DIR/cli.zip" "$member" "${BIN_DIR}/$(bin_name "$p")" \
            || fail "Failed to extract ${member} from the bundle (is 'unzip' installed?). Build via hub/${MODULE_ID}/build-binaries.sh as a fallback."
        chmod 0755 "${BIN_DIR}/$(bin_name "$p")"
        msg "  installed $(bin_name "$p") (from $(basename "$zip_url"))"
    done
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

install_payload
install_binaries

if [ -x /etc/init.d/krot-wlb ]; then
    /etc/init.d/krot-wlb enable >/dev/null 2>&1 || true
    /etc/init.d/krot-wlb restart >/dev/null 2>&1 || true
fi

# Make LuCI pick up the new menu entry and ACL.
/etc/init.d/rpcd restart >/dev/null 2>&1 || true

msg ""
msg "Whitelist Bypass installed successfully"
msg ""
msg "Next steps:"
msg "  1. Re-login to LuCI (ACL refresh), then open: K.R.O.T. -> Servers -> Add"
msg "  2. Pick protocol 'Whitelist Bypass', press 'QR Login with Yandex' (or paste cookies)"
msg "  3. Save & Apply, wait for the link, press the info button and scan the QR with the mobile app"
msg ""
