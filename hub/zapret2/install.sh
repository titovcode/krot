#!/bin/sh
# Zapret2 provider installer for K.R.O.T. Hub
# Source: https://github.com/bol-van/zapret2
#
# K.R.O.T. runs action=zapret through an external provider binary that it
# expects at a fixed path (see ZAPRET_PROVIDER_NFQWS_BIN in constants.sh):
#     /opt/zapret/nfq/nfqws
# plus the fake-payload library referenced by the default strategies
#     /opt/zapret/files/fake/*.bin
# This installer lays the upstream release out so those paths resolve. It does
# not install any init script: K.R.O.T. owns the nfqws2 lifecycle, its NFQUEUE
# range and its restart/respawn logic, and a second service would fight it for
# the same queues.
set -e

GITHUB_REPO="bol-van/zapret2"
TARGET_DIR="/opt/zapret"
NFQ_DIR="$TARGET_DIR/nfq"
NFQ_BIN="$NFQ_DIR/nfqws"
VERSION_FILE="$TARGET_DIR/VERSION"
TMP_DIR="$(mktemp -d /tmp/hub-zapret2.XXXXXX 2>/dev/null || mktemp -d /tmp/hub-zapret2.$$)"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM

fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }
msg()  { printf '\033[32m%s\033[0m\n' "$1"; }

PKG_IS_APK=0
command -v apk >/dev/null 2>&1 && PKG_IS_APK=1

# ── proxy from K.R.O.T. settings (consistent with the other hub installers) ──
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
        http_proxy="$PROXY_ADDR" https_proxy="$PROXY_ADDR" wget -qO --timeout=300 "$1" -O "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO --timeout=300 "$1" -O "$2"
    else
        fail "wget or curl is required"
    fi
}

# ── 1. Resolve the latest release and its OpenWrt bundle ────────────────────
msg "Fetching latest Zapret2 release..."
RELEASE_JSON="$(http_get "https://api.github.com/repos/${GITHUB_REPO}/releases/latest")" \
    || fail "Failed to fetch release info from GitHub"
[ -n "$RELEASE_JSON" ] || fail "Empty response from GitHub API"

VERSION="$(printf '%s' "$RELEASE_JSON" \
    | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
    | sed 's/^.*"tag_name"[[:space:]]*:[[:space:]]*"//; s/"$//')"
[ -n "$VERSION" ] || fail "Could not determine the latest Zapret2 version"
msg "Latest version: $VERSION"

ASSET_URL="$(printf '%s' "$RELEASE_JSON" \
    | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*openwrt-embedded[^"]*"' | head -1 \
    | sed 's/^.*"browser_download_url"[[:space:]]*:[[:space:]]*"//; s/"$//')"
[ -n "$ASSET_URL" ] || fail "The release has no openwrt-embedded asset"

msg "Downloading $(basename "$ASSET_URL")..."
http_download "$ASSET_URL" "$TMP_DIR/zapret2.tgz" || fail "Download failed"
[ -s "$TMP_DIR/zapret2.tgz" ] || fail "Downloaded archive is empty"

# ── 2. Extract ─────────────────────────────────────────────────────────────
command -v tar >/dev/null 2>&1 || fail "tar is required"
tar xzf "$TMP_DIR/zapret2.tgz" -C "$TMP_DIR" || fail "Extraction failed"

SRC_DIR="$TMP_DIR/zapret2-${VERSION#v}"
[ -d "$SRC_DIR" ] || SRC_DIR="$(find "$TMP_DIR" -maxdepth 1 -type d -name 'zapret2-*' | head -1)"
[ -n "$SRC_DIR" ] && [ -d "$SRC_DIR" ] || fail "Unexpected archive layout"

# ── 3. Pick the binary set matching this router ────────────────────────────
# The release ships one directory per target triple. Match on the router's
# uname instead of the package architecture: opkg reports e.g. "aarch64_cortex-a53"
# while the upstream directory is named by the plain machine type.
UNAME_M="$(uname -m 2>/dev/null)"
case "$UNAME_M" in
x86_64)          ARCH_DIR="linux-x86_64" ;;
aarch64 | arm64) ARCH_DIR="linux-arm64" ;;
armv7* | armv6* | arm) ARCH_DIR="linux-arm" ;;
mips)            ARCH_DIR="linux-mips" ;;
mipsel)          ARCH_DIR="linux-mipsel" ;;
mips64)          ARCH_DIR="linux-mips64" ;;
mips64el)        ARCH_DIR="linux-mips64el" ;;
powerpc)         ARCH_DIR="linux-ppc" ;;
*)               ARCH_DIR="" ;;
esac

SRC_BIN_DIR=""
if [ -n "$ARCH_DIR" ] && [ -x "$SRC_DIR/binaries/$ARCH_DIR/nfqws2" ]; then
    SRC_BIN_DIR="$SRC_DIR/binaries/$ARCH_DIR"
else
    # Fall back to the first shipped build that can execute here. The release
    # binaries are static, so a successful run is proof of the architecture.
    for candidate in "$SRC_DIR"/binaries/*/nfqws2; do
        [ -x "$candidate" ] || continue
        if "$candidate" --version >/dev/null 2>&1; then
            SRC_BIN_DIR="$(dirname "$candidate")"
            break
        fi
    done
fi
[ -n "$SRC_BIN_DIR" ] || fail "No executable nfqws2 build found for '$UNAME_M' in this release"
msg "Using binaries from $(basename "$SRC_BIN_DIR")"

# ── 4. Lay out the provider tree K.R.O.T. expects ───────────────────────────
# Staged in a sibling directory and swapped in, so an interrupted install never
# leaves K.R.O.T. with a half-populated provider directory.
STAGE_DIR="$TARGET_DIR.new.$$"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR" "$STAGE_DIR/nfq" "$STAGE_DIR/files" || fail "Failed to create $STAGE_DIR"

cp "$SRC_BIN_DIR/nfqws2" "$STAGE_DIR/nfq/nfqws" || fail "Failed to stage nfqws2"
chmod 0755 "$STAGE_DIR/nfq/nfqws"

# The default strategies embed paths like
# /opt/zapret/files/fake/quic_initial_www_google_com.bin - without the fake
# payload library the process starts but the strategy silently misbehaves.
if [ -d "$SRC_DIR/files/fake" ]; then
    cp -R "$SRC_DIR/files/fake" "$STAGE_DIR/files/" || fail "Failed to stage the fake payload library"
else
    fail "Release does not contain files/fake"
fi

# Auxiliary tools and libraries upstream ships alongside the binary. They are not
# required by K.R.O.T., but keeping them here makes the installation match the
# upstream layout and lets users use ip2net/mdig directly.
for extra in ip2net mdig; do
    [ -x "$SRC_BIN_DIR/$extra" ] && cp "$SRC_BIN_DIR/$extra" "$STAGE_DIR/$extra" 2>/dev/null || true
done
for dir in common ipset lua; do
    [ -d "$SRC_DIR/$dir" ] && cp -R "$SRC_DIR/$dir" "$STAGE_DIR/" 2>/dev/null || true
done
chmod 0755 "$STAGE_DIR"/ip2net "$STAGE_DIR"/mdig 2>/dev/null || true

# Record the version so the Hub status line can report it without re-querying.
printf '%s\n' "$VERSION" > "$STAGE_DIR/VERSION"
printf '%s\n' "$VERSION" > "$STAGE_DIR/VERSION.embedded"

find "$STAGE_DIR" -type d -exec chmod 0755 {} \; 2>/dev/null || true
find "$STAGE_DIR" -type f -exec chmod 0644 {} \; 2>/dev/null || true
chmod 0755 "$STAGE_DIR/nfq/nfqws" 2>/dev/null || true
chmod 0755 "$STAGE_DIR"/ip2net "$STAGE_DIR"/mdig 2>/dev/null || true

# Verify the staged binary before swapping: a provider that cannot report its
# version is worse than no provider, because K.R.O.T. would start it and get
# nothing.
"$STAGE_DIR/nfq/nfqws" --version >/dev/null 2>&1 || fail "Staged nfqws2 does not run on this router"

# Carry over the files an existing zapret installation may have customised, so
# replacing the provider does not silently reset a working setup. K.R.O.T. reads
# its strategy from UCI and does not need these, but they belong to the user.
if [ -d "$TARGET_DIR" ]; then
    for keep in config config.backup ipset_def; do
        [ -f "$TARGET_DIR/$keep" ] && cp "$TARGET_DIR/$keep" "$STAGE_DIR/$keep" 2>/dev/null || true
    done
    chmod 0600 "$STAGE_DIR"/config "$STAGE_DIR"/config.backup 2>/dev/null || true
fi

# Swap: keep the previous tree as a rollback copy until the new one is live.
BACKUP_DIR="$TARGET_DIR.old.$$"
[ -d "$TARGET_DIR" ] && mv "$TARGET_DIR" "$BACKUP_DIR"
mv "$STAGE_DIR" "$TARGET_DIR" || {
    [ -d "$BACKUP_DIR" ] && mv "$BACKUP_DIR" "$TARGET_DIR"
    fail "Failed to activate the new provider tree"
}
rm -rf "$BACKUP_DIR" 2>/dev/null || true

# A standalone zapret/zapret2 service would fight K.R.O.T. for the same queues.
for svc in zapret zapret2; do
    if [ -x "/etc/init.d/$svc" ]; then
        "/etc/init.d/$svc" stop 2>/dev/null || true
        "/etc/init.d/$svc" disable 2>/dev/null || true
    fi
done

# Pick up the new provider: K.R.O.T. re-evaluates the provider on reload and
# starts the nfqws2 processes itself.
if [ -x /etc/init.d/krot ]; then
    msg "Reloading K.R.O.T. to pick up the provider..."
    /etc/init.d/krot reload 2>/dev/null || true
fi

INSTALLED_VERSION="$("$NFQ_BIN" --version 2>/dev/null | sed -n '1s/^.*version[[:space:]]*//p' | awk '{print $1; exit}')"
msg ""
msg "Zapret2 installed successfully"
msg "Release:     $VERSION"
msg "Provider:    $NFQ_BIN ($INSTALLED_VERSION)"
msg "Fake files:  $TARGET_DIR/files/fake"
msg ""
msg "Enable it from K.R.O.T. -> Rules: set a rule's action to 'zapret' and"
msg "attach it to the domains you need. K.R.O.T. starts and supervises the"
msg "process itself, so there is no separate service to manage."
msg ""
