#!/bin/sh
# OpenFlux Exit Node installer for K.R.O.T. Hub
# Upstream: https://github.com/p1neappleXpress/OpenFlux
# Setup guide: https://github.com/p1neappleXpress/OpenFlux/issues/44
#
# Same layout as hub/olcrtc: everything is generated inline by this script,
# the module has its own static web panel at /www/openflux/ and NO LuCI
# menu/ACL (so rpcd is never restarted and LuCI sessions survive install).
#
# Environment overrides (testing / forks / custom builds):
#   OF_REPO / OF_BRANCH      GitHub repo with the module (default titovcode/krot)
#   OF_PAYLOAD_DIR=./files   Local dir with payload files (skip downloading)
#   OF_BIN_BASE=https://...  Base URL serving openflux-linux-<arch> files
#   OF_RELEASE_REPO          Releases to look the binary up in
#                            (default titovcode/krot, tag openflux-0.1.0)
set -e

MODULE_ID="openflux"
MODULE_VERSION="0.2.5"
OF_REPO="${OF_REPO:-titovcode/krot}"
OF_BRANCH="${OF_BRANCH:-main}"
OF_PAYLOAD_DIR="${OF_PAYLOAD_DIR:-}"
OF_BIN_BASE="${OF_BIN_BASE:-}"
OF_RELEASE_REPO="${OF_RELEASE_REPO:-titovcode/krot}"
OF_TAG="${OF_TAG:-openflux-0.1.0}"
UPSTREAM_RELEASE_REPO="p1neappleXpress/OpenFlux"

RAW_BASE="https://raw.githubusercontent.com/${OF_REPO}/${OF_BRANCH}/hub/${MODULE_ID}"
GITHUB_API="https://api.github.com"

OF_DIR="/opt/openflux"
OF_BIN="$OF_DIR/openflux"
OF_RUNNER="$OF_DIR/openflux-run.sh"
OF_VERSION="$OF_DIR/VERSION"
OF_INIT="/etc/init.d/krot-openflux"
OF_CONFIG="/etc/config/krot_openflux"
OF_STATE="/etc/openflux"
OF_WWW="/www/openflux"
OF_TMP="$(mktemp -d /tmp/hub-openflux.XXXXXX 2>/dev/null || { mkdir -p /tmp/hub-openflux.$$; echo /tmp/hub-openflux.$$; })"

cleanup() { rm -rf "$OF_TMP"; }
trap cleanup EXIT HUP INT TERM

fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }
msg()  { printf '\033[32m%s\033[0m\n' "$1"; }
warn() { printf '\033[33m%s\033[0m\n' "$1"; }

# Resolve the module source repo/branch (custom Hub source wins over default).
REPO="${OF_REPO_OVERRIDE:-$(uci -q get krot.hub_source_openflux.repo 2>/dev/null || true)}"
REPO="${REPO:-$OF_REPO}"
BRANCH="${OF_BRANCH_OVERRIDE:-$(uci -q get krot.hub_source_openflux.branch 2>/dev/null || true)}"
BRANCH="${BRANCH:-$OF_BRANCH}"

# ---------------------------------------------------------------------------
# Download helpers (same conventions as other K.R.O.T. Hub modules)
# ---------------------------------------------------------------------------

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

# ELF magic without od/hexdump: "\177ELF" has no NUL byte, so command
# substitution preserves it and = compares byte-for-byte. Some busybox
# firmships ship without coreutils od (that broke the panel download).
is_elf() { [ "$(head -c 4 "$1" 2>/dev/null)" = "$(printf '\177ELF')" ]; }

# ---------------------------------------------------------------------------
# 0. Migrate/clean leftovers from the 0.1.x LuCI-based layout (0.2.x ships a
#    standalone web panel at /www/openflux/ and no LuCI integration).
# ---------------------------------------------------------------------------

cleanup_legacy_layout() {
    msg "Cleaning up any 0.1.x leftovers..."
    rm -f /usr/share/luci/menu.d/krot-openflux.json
    rm -f /usr/share/rpcd/acl.d/krot-openflux.json
    rm -rf /www/luci-static/resources/view/krot-openflux
    rm -rf /usr/lib/krot-openflux
    # Refresh LuCI caches so the stale "OpenFlux Exit Node" menu entry
    # disappears from K.R.O.T.
    rm -rf /tmp/luci-indexcache* 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 1. Binary
# ---------------------------------------------------------------------------

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)        BIN_LABEL="amd64" ;;
    aarch64|arm64) BIN_LABEL="arm64" ;;
    armv7l|armv7)  BIN_LABEL="armv7" ;;
    armv6l|armv6)  BIN_LABEL="armv6" ;;
    mipsel)        BIN_LABEL="mipsle" ;;
    mips)          BIN_LABEL="mips" ;;
    mips64el)      BIN_LABEL="mips64le" ;;
    *) fail "Unsupported architecture: $ARCH (openflux is a Go binary; build it with hub/${MODULE_ID}/build-binaries.sh)" ;;
esac

install_binary() {
    if [ -x "$OF_BIN" ]; then
        msg "openflux binary already present at $OF_BIN"
        return 0
    fi
    if [ -f /tmp/openflux ]; then
        msg "Installing manually placed binary from /tmp/openflux..."
        mkdir -p "$OF_DIR"
        cp /tmp/openflux "$OF_BIN" && chmod 0755 "$OF_BIN"
        msg "installed openflux (from /tmp/openflux)"
        return 0
    fi
    if [ -n "$OF_PAYLOAD_DIR" ] && [ -f "$OF_PAYLOAD_DIR/bin/openflux-linux-${BIN_LABEL}" ]; then
        msg "Installing binary from payload..."
        mkdir -p "$OF_DIR"
        cp "$OF_PAYLOAD_DIR/bin/openflux-linux-${BIN_LABEL}" "$OF_BIN"
        chmod 0755 "$OF_BIN"
        msg "installed openflux (from payload)"
        return 0
    fi

    # Read bin_base from UCI config if not set via environment.
    # This makes "Update" in the web panel actually work: the panel saves
    # bin_base to /etc/config/krot_openflux, and update.sh re-runs install.sh,
    # which must pick it up here.
    local uci_bin_base=""
    if command -v uci >/dev/null 2>&1 && [ -f "$OF_CONFIG" ]; then
        uci_bin_base="$(uci -q get krot_openflux.settings.bin_base 2>/dev/null || true)"
    fi
    local base=""
    if [ -n "$OF_BIN_BASE" ]; then
        base="${OF_BIN_BASE%/}"
    elif [ -n "$uci_bin_base" ]; then
        base="${uci_bin_base%/}"
    else
        base="https://github.com/${OF_RELEASE_REPO}/releases/download/${OF_TAG}"
    fi

    # Users often paste the release *page* URL from the browser; rewrite it to
    # the download base so the asset URL resolves instead of 404-ing.
    case "$base" in
        */releases/tag/*) base="$(printf '%s' "$base" | sed 's,/releases/tag/,/releases/download/,')" ;;
    esac

    msg "Architecture: $ARCH (label: $BIN_LABEL)"
    msg "Downloading openflux from ${base}/openflux-linux-${BIN_LABEL} ..."

    # Delegate to the shared downloader (same code path as the panel button)
    # so install and "Скачать бинарник" always behave identically. It exits 0
    # on success and leaves the binary in place.
    if [ -x "$OF_DIR/fetch-binary.sh" ]; then
        OF_BIN_BASE="$base" sh "$OF_DIR/fetch-binary.sh" 2>/dev/null || true
        if [ -x "$OF_BIN" ]; then
            msg "installed openflux (downloaded from ${base})"
            return 0
        fi
    fi

    warn "No openflux-linux-${BIN_LABEL} binary could be downloaded automatically."
    warn "The module is installed, but the service will stay stopped until the"
    warn "binary is in place. Options:"
    warn "  1. Build it: hub/${MODULE_ID}/build-binaries.sh (needs Go), then copy"
    warn "     scp openflux-linux-${BIN_LABEL} root@<router-ip>:/tmp/openflux"
    warn "     and run the install again (it picks /tmp/openflux up), or"
    warn "  2. Host the binary at a URL and set bin_base on the web panel"
    warn "     (http://<router-ip>/openflux/), then press Update."
    warn "Issue #44 places the binary at /usr/bin/openflux built from source"
    warn "(see https://github.com/p1neappleXpress/OpenFlux/issues/44)."
    return 0
}

# ---------------------------------------------------------------------------
# 2. UCI config (only on first install; existing config is preserved)
# ---------------------------------------------------------------------------

install_config() {
    if [ -f "$OF_CONFIG" ]; then
        return 0
    fi
    msg "Generating default $OF_CONFIG..."
    cat > "$OF_CONFIG" <<EOF
# K.R.O.T. OpenFlux Exit Node module configuration.
# Manage from the web panel: http://<router-ip>/openflux/

config settings 'settings'
	option bin_base ''
	option use_iptables '0'
	option suppress_rst '1'

# One instance = one running openflux exit node = one phone (one Yandex doc).
# Add another instance (and another Yandex doc) for every additional phone,
# see issue #44 "one link = one device".
#
#config instance 'phone1'
#	option enabled '1'
#	option label 'My phone'
#	option transport 'yandex'           # yandex | vyandex | oneme | cupsonline | mailru
#	option exit_mode 'l3'               # l3 (raw SNAT/DNAT, root) | l4 (gVisor, no root)
#	option url ''                       # yandex/vyandex/mailru: doc URL; cupsonline: rooms base64
#	option max_token ''                 # oneme: MAX authorization token
#	option max_uid ''                   # oneme: MAX user id
#	option listen_port '4545'           # l4 mode SOCKS fallback listener (localhost only)
#	option codec 'batched'              # batched | legacy (must match the client)
#	option encryption_key ''            # optional shared secret (AES-256-GCM)
#	option local_ip ''                  # egress IP for l3 SNAT/RST filter (empty = auto)
#	option debug '0'
EOF
    chmod 0600 "$OF_CONFIG"
}

# ---------------------------------------------------------------------------
# 3. Web panel (static, like hub/olcrtc; served by uhttpd from /www)
# ---------------------------------------------------------------------------

install_webpanel() {
    if [ -n "$OF_PAYLOAD_DIR" ] && [ -f "$OF_PAYLOAD_DIR/www/index.html" ]; then
        mkdir -p "$OF_WWW"
        cp "$OF_PAYLOAD_DIR/www/index.html" "$OF_WWW/index.html"
    else
        mkdir -p "$OF_WWW"
        http_download "${RAW_BASE}/www/index.html" "$OF_WWW/index.html" \
            || fail "Failed to download the web panel (does your repo contain hub/${MODULE_ID}/www/index.html?)"
    fi
    chmod 0644 "$OF_WWW/index.html"

    cat > "$OF_WWW/state.js" <<'SH'
window.OPENFLUX = { instances: [], settings: {} };
SH
    chmod 0644 "$OF_WWW/state.js"
}

# ---------------------------------------------------------------------------
# 3b. CGI backend (/www/cgi-bin/openflux) — status / restart / save.
#     uhttpd executes scripts under /www/cgi-bin/* as /cgi-bin/*.
# ---------------------------------------------------------------------------

install_cgi() {
    cat > /www/cgi-bin/openflux <<'CGISH'
#!/bin/sh
# CGI backend for the OpenFlux web panel (uhttpd /cgi-bin/openflux).
# Actions: status | restart | save_settings | save_instance | del_instance
# uhttpd passes the POST body on stdin (application/x-www-form-urlencoded).
export IPKG_INSTROOT="${IPKG_INSTROOT:-}"
. /lib/functions.sh

CONFIG="krot_openflux"
INIT="/etc/init.d/krot-openflux"
GEN_STATE="/opt/openflux/gen-state.sh"

emit() { printf 'Content-Type: application/json\r\n\r\n%s\n' "$1"; }

# Minimal URL-decoder (busybox sh; keeps + as space, resolves %XX).
urldecode() {
    printf '%s' "$1" \
        | sed 's/%\([0-9a-fA-F][0-9a-fA-F]\)/\\x\1/g' \
        | while IFS= read -r -d '' 2>/dev/null || IFS= read -r line; do printf '%b' "$line"; done \
        2>/dev/null
}

urldecode() {
    # POSIX-safe variant: percent-decode via printf '%b' on a \x-escaped string.
    printf '%b' "$(printf '%s' "$1" | sed 's/%\([0-9a-fA-F][0-9a-fA-F]\)/\\x\1/g; s/+/ /g')"
}

QUERY_STRING="$(cat 2>/dev/null)"
ACTION=""
PAYLOAD=""
for kv in $(printf '%s' "$QUERY_STRING" | tr '&' ' '); do
    key="${kv%%=*}"
    val="${kv#*=}"
    key="$(urldecode "$key")"
    val="$(urldecode "$val")"
    case "$key" in
        action) ACTION="$val" ;;
        payload) PAYLOAD="$val" ;;
    esac
done

json_get() {
    # json_get <json> <key> — extract a simple string field (sed-based).
    printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p"
}

regen_state() {
    [ -x "$GEN_STATE" ] && "$GEN_STATE" >/dev/null 2>&1
}

case "$ACTION" in
    status)
        svc="$("$INIT" status 2>/dev/null || echo stopped)"
        case "$svc" in
            *running*) emit "{\"status\":\"running\",\"bin\":$([ -x /opt/openflux/openflux ] && echo true || echo false)}" ;;
            *) emit "{\"status\":\"stopped\",\"bin\":$([ -x /opt/openflux/openflux ] && echo true || echo false)}" ;;
        esac
        ;;
    restart)
        "$INIT" restart >/dev/null 2>&1 || true
        emit '{"ok":true}'
        ;;
    fetch_binary)
        # Download the openflux binary for this architecture using bin_base
        # from UCI (falls back to the pinned module release). Runs in the
        # background: uhttpd CGIs are short-lived, a 12 MB download is not.
        (
            OF_BIN_BASE="$(uci -q get "$CONFIG.settings.bin_base" 2>/dev/null || true)"
            export OF_BIN_BASE
            /opt/openflux/fetch-binary.sh >/tmp/openflux-fetch.log 2>&1 || true
            regen_state
            "$INIT" restart >/dev/null 2>&1 || true
        ) >/dev/null 2>&1 &
        emit '{"ok":true,"started":true}'
        ;;
    fetch_status)
        # Report progress of a running/finished fetch for the panel poller.
        LOG="/tmp/openflux-fetch.log"
        if [ -x /opt/openflux/openflux ]; then
            emit '{"state":"done","bin":true}'
        elif [ -f "$LOG" ]; then
            tail -n 3 "$LOG" 2>/dev/null | tr '\n' ' ' | sed 's/"/\\"/g' > /tmp/of-msg 2>/dev/null
            printf 'Content-Type: application/json\r\n\r\n{"state":"running","msg":"%s"}\n' "$(cat /tmp/of-msg 2>/dev/null)"
        else
            emit '{"state":"idle"}'
        fi
        ;;
    logs)
        # Last ~40 lines relevant to openflux: the runner (krot-openflux[*]),
        # the binary itself, and procd service events.
        {
            echo "=== service ==="
            "$INIT" status 2>/dev/null || echo "unknown"
            echo "=== binary ==="
            if [ -x /opt/openflux/openflux ]; then
                ls -l /opt/openflux/openflux 2>/dev/null
                file /opt/openflux/openflux 2>/dev/null || echo "present"
            else
                echo "missing"
            fi
            echo "=== logread ==="
            if command -v logread >/dev/null 2>&1; then
                logread 2>/dev/null | grep -E 'krot-openflux|openflux' | tail -n 40
            else
                # fall back to the kernel ring buffer
                dmesg 2>/dev/null | grep -E 'krot-openflux|openflux' | tail -n 40
            fi
            echo "=== fetch log ==="
            tail -n 10 /tmp/openflux-fetch.log 2>/dev/null || echo "(none)"
            # The runner redirects the binary's own output here; this is where
            # the real crash reason shows up in a respawn loop.
            for f in /tmp/openflux-*.log; do
                [ -f "$f" ] || continue
                echo "=== $f ==="
                tail -n 30 "$f" 2>/dev/null
            done
        } > /tmp/of-logs.txt 2>&1
        # JSON-escape the whole dump: backslash, quote, then join lines with \n.
        ESC="$(awk 'BEGIN{ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); if (NR>1) printf "\\n"; print}' /tmp/of-logs.txt 2>/dev/null)"
        printf 'Content-Type: application/json\r\n\r\n{"ok":true,"logs":"%s"}\n' "$ESC"
        ;;
    save_settings)
        [ -f "/etc/config/$CONFIG" ] || { emit '{"ok":false,"error":"no config"}'; exit 0; }
        uci -q set "$CONFIG.settings.bin_base=$(json_get "$PAYLOAD" bin_base)"
        SUPPRESS="$(json_get "$PAYLOAD" suppress_rst)"
        [ -n "$SUPPRESS" ] && uci -q set "$CONFIG.settings.suppress_rst=$SUPPRESS"
        USEIPT="$(json_get "$PAYLOAD" use_iptables)"
        [ -n "$USEIPT" ] && uci -q set "$CONFIG.settings.use_iptables=$USEIPT"
        uci -q commit "$CONFIG"
        regen_state
        emit '{"ok":true}'
        ;;
    save_instance)
        [ -f "/etc/config/$CONFIG" ] || { emit '{"ok":false,"error":"no config"}'; exit 0; }
        ID="$(json_get "$PAYLOAD" id)"
        if [ -z "$ID" ]; then
            uci -q add "$CONFIG" instance >/dev/null
            ID="$(uci -q show "$CONFIG" | grep '=instance' | tail -1 | cut -d. -f2 | cut -d= -f1)"
        fi
        [ -n "$ID" ] || { emit '{"ok":false,"error":"cannot create section"}'; exit 0; }

        LABEL="$(json_get "$PAYLOAD" label)"
        TRANSPORT="$(json_get "$PAYLOAD" transport)"
        EXITMODE="$(json_get "$PAYLOAD" exit_mode)"
        CODEC="$(json_get "$PAYLOAD" codec)"
        PORT="$(json_get "$PAYLOAD" listen_port)"

        uci -q set "$CONFIG.$ID.label=$LABEL"
        [ -n "$TRANSPORT" ] && uci -q set "$CONFIG.$ID.transport=$TRANSPORT"
        [ -n "$EXITMODE" ] && uci -q set "$CONFIG.$ID.exit_mode=$EXITMODE"
        uci -q set "$CONFIG.$ID.url=$(json_get "$PAYLOAD" url)"
        uci -q set "$CONFIG.$ID.max_token=$(json_get "$PAYLOAD" max_token)"
        uci -q set "$CONFIG.$ID.max_uid=$(json_get "$PAYLOAD" max_uid)"
        [ -n "$CODEC" ] && uci -q set "$CONFIG.$ID.codec=$CODEC"
        ENCKEY="$(json_get "$PAYLOAD" encryption_key)"
        if [ -n "$ENCKEY" ] && [ "${#ENCKEY}" -lt 16 ]; then
            emit '{"ok":false,"error":"encryption_key must be at least 16 characters (or empty to disable)"}'
            exit 0
        fi
        # An empty value must clear the stored option, not write an empty one.
        if [ -n "$ENCKEY" ]; then
            uci -q set "$CONFIG.$ID.encryption_key=$ENCKEY"
        else
            uci -q delete "$CONFIG.$ID.encryption_key" 2>/dev/null || true
        fi
        uci -q set "$CONFIG.$ID.listen_port=${PORT:-4545}"
        uci -q set "$CONFIG.$ID.local_ip=$(json_get "$PAYLOAD" local_ip)"
        uci -q set "$CONFIG.$ID.enabled=1"
        uci -q commit "$CONFIG"
        regen_state
        "$INIT" restart >/dev/null 2>&1 &
        emit "{\"ok\":true,\"id\":\"$ID\"}"
        ;;
    del_instance)
        ID="$(json_get "$PAYLOAD" id)"
        [ -n "$ID" ] || { emit '{"ok":false,"error":"no id"}'; exit 0; }
        uci -q delete "$CONFIG.$ID"
        uci -q commit "$CONFIG"
        regen_state
        "$INIT" restart >/dev/null 2>&1 &
        emit '{"ok":true}'
        ;;
    *)
        emit '{"ok":false,"error":"unknown action"}'
        ;;
esac
CGISH
    chmod 0755 /www/cgi-bin/openflux
}

# ---------------------------------------------------------------------------
# 4. Runner
# ---------------------------------------------------------------------------

install_runner() {
    if [ -n "$OF_PAYLOAD_DIR" ] && [ -f "$OF_PAYLOAD_DIR/files/usr/lib/krot-openflux/openflux-run.sh" ]; then
        mkdir -p "$OF_DIR"
        cp "$OF_PAYLOAD_DIR/files/usr/lib/krot-openflux/openflux-run.sh" "$OF_DIR/openflux-run.sh"
    elif [ -n "$OF_PAYLOAD_DIR" ] && [ -f "$OF_PAYLOAD_DIR/usr/lib/krot-openflux/openflux-run.sh" ]; then
        mkdir -p "$OF_DIR"
        cp "$OF_PAYLOAD_DIR/usr/lib/krot-openflux/openflux-run.sh" "$OF_DIR/openflux-run.sh"
    else
        mkdir -p "$OF_DIR"
        http_download "${RAW_BASE}/files/usr/lib/krot-openflux/openflux-run.sh" "$OF_DIR/openflux-run.sh" \
            || fail "Failed to download openflux-run.sh"
    fi
    chmod 0755 "$OF_DIR/openflux-run.sh"
    echo "$MODULE_VERSION" > "$OF_VERSION"
}

# ---------------------------------------------------------------------------
# 5. procd service (generated inline, like hub/olcrtc/install.sh)
# ---------------------------------------------------------------------------

install_init() {
    cat > "$OF_INIT" <<'SH'
#!/bin/sh /etc/rc.common
# shellcheck disable=SC2034,SC2154
# krot-openflux: OpenFlux exit-node instances (one procd instance per UCI section)

START=90
STOP=10
USE_PROCD=1

OF_BIN="/opt/openflux/openflux"
OF_RUNNER="/opt/openflux/openflux-run.sh"

start_service() {
    [ -f /etc/config/krot_openflux ] || return 0
    [ -x "$OF_RUNNER" ] || return 0

    . /lib/functions.sh
    config_load krot_openflux
    config_foreach openflux_spawn instance
}

openflux_spawn() {
    local section="$1"
    local enabled
    config_get_bool enabled "$section" enabled 0
    [ "$enabled" -eq 1 ] || return 0

    procd_open_instance "krot-openflux-$section"
    procd_set_param command /bin/sh "$OF_RUNNER" "$section"
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param file /etc/config/krot_openflux
    procd_close_instance
}

reload_service() {
    restart
}

service_triggers() {
    procd_add_reload_trigger krot_openflux
}
SH
    chmod 0755 "$OF_INIT"
}

# ---------------------------------------------------------------------------
# 6. state.js generator (exposes config + service state to the web panel)
# ---------------------------------------------------------------------------

install_state_gen() {
    cat > "$OF_DIR/gen-state.sh" <<'GENSH'
#!/bin/sh
# Regenerates /www/openflux/state.js (instances + settings) from UCI config.
export IPKG_INSTROOT="${IPKG_INSTROOT:-}"
. /lib/functions.sh
[ -f /etc/config/krot_openflux ] || exit 0
config_load krot_openflux

STATE_JS="/www/openflux/state.js"
mkdir -p "$(dirname "$STATE_JS")"

json_escape() {
    # JSON-escape: backslash, quote, and control chars that break JSON strings.
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g' | tr -d '\000-\010\013\014\016-\037'
}

# Track whether we already printed one array element (for comma separation).
first=1

# Functions must be declared BEFORE config_foreach uses them.
instance_json() {
    local section="$1"
    local enabled label transport exit_mode url max_token max_uid listen_port codec local_ip debug
    config_get_bool enabled "$section" enabled 0
    config_get label "$section" "label" "$section"
    config_get transport "$section" "transport" "yandex"
    config_get exit_mode "$section" "exit_mode" "l3"
    config_get url "$section" "url" ""
    config_get max_token "$section" "max_token" ""
    config_get max_uid "$section" "max_uid" ""
    config_get listen_port "$section" "listen_port" "4545"
    config_get codec "$section" "codec" "batched"
    config_get local_ip "$section" "local_ip" ""
    config_get debug "$section" "debug" "0"

    [ "$first" -eq 0 ] && printf ','
    first=0
    printf '{ "id": "%s", "label": "%s", "transport": "%s", "exit_mode": "%s", "url": "%s", "max_token": "%s", "max_uid": "%s", "listen_port": "%s", "codec": "%s", "local_ip": "%s", "debug": "%s", "enabled": %s }\n' \
        "$(json_escape "$section")" \
        "$(json_escape "$label")" \
        "$(json_escape "$transport")" \
        "$(json_escape "$exit_mode")" \
        "$(json_escape "$url")" \
        "$(json_escape "$max_token")" \
        "$(json_escape "$max_uid")" \
        "$(json_escape "$listen_port")" \
        "$(json_escape "$codec")" \
        "$(json_escape "$local_ip")" \
        "$(json_escape "$debug")" \
        "$([ "$enabled" -eq 1 ] && echo true || echo false)"
}

OUT="/www/openflux/state.js.tmp"
{
    printf 'window.OPENFLUX = { arch: "'
    printf '%s' "$(json_escape "$(uname -m)")"
    printf '", bin_present: %s, instances: [' "$([ -x /opt/openflux/openflux ] && echo true || echo false)"
    first=1
    config_foreach instance_json instance
    printf ' ], settings: { bin_base: "'
    printf '%s' "$(json_escape "$(uci -q get krot_openflux.settings.bin_base 2>/dev/null)")"
    printf '", use_iptables: "'
    printf '%s' "$(uci -q get krot_openflux.settings.use_iptables 2>/dev/null || echo 0)"
    printf '", suppress_rst: "'
    printf '%s' "$(uci -q get krot_openflux.settings.suppress_rst 2>/dev/null || echo 1)"
    printf '" } };\n'
} > "$OUT"

mv "$OUT" "$STATE_JS"
chmod 0644 "$STATE_JS"
GENSH
    chmod 0755 "$OF_DIR/gen-state.sh"
}

# ---------------------------------------------------------------------------
# 6b. fetch-binary.sh — standalone downloader used by the panel button.
#     Same resolution order as install_binary(): UCI bin_base (with the
#     common /releases/tag/ -> /releases/download/ typo fix) -> pinned release.
# ---------------------------------------------------------------------------

install_fetch_binary() {
    cat > "$OF_DIR/fetch-binary.sh" <<'FETCHSH'
#!/bin/sh
# fetch-binary.sh — download the openflux binary for this router's arch.
# Used both at module install and by the panel "Скачать бинарник" button,
# so both paths behave identically.
# Writes /tmp/openflux-fetch.status for the panel poller; when FETCH_RESTART=1
# (panel button) it also regenerates state.js and restarts the service.
OF_DIR="/opt/openflux"
OF_BIN="$OF_DIR/openflux"
OF_TAG="openflux-0.1.0"
OF_RELEASE_REPO="${OF_RELEASE_REPO:-titovcode/krot}"
UPSTREAM_RELEASE_REPO="p1neappleXpress/OpenFlux"
GITHUB_API="https://api.github.com"
LOG="/tmp/openflux-fetch.log"
STATUS_FILE="/tmp/openflux-fetch.status"
PID_FILE="/tmp/openflux-fetch.pid"

log() { echo "$*"; }
set_status() { printf '%s\n%s\n' "$1" "$2" > "$STATUS_FILE" 2>/dev/null || true; }

is_elf() { [ "$(head -c 4 "$1" 2>/dev/null)" = "$(printf '\177ELF')" ]; }

# Same proxy handling as install.sh: route through K.R.O.T.'s mixed inbound
# when the user opted into downloading lists/updates via proxy.
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
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout=30 "$1"
    else
        log "ERROR: curl or wget is required"; set_status failed "no curl/wget"; exit 1
    fi
}

http_download() {
    # http_download <url> <dest>
    if [ -n "$PROXY_ADDR" ] && command -v curl >/dev/null 2>&1; then
        curl -fSL --connect-timeout 15 --max-time 900 -x "$PROXY_ADDR" "$1" -o "$2"
    elif command -v curl >/dev/null 2>&1; then
        curl -fSL --connect-timeout 15 --max-time 900 "$1" -o "$2"
    elif [ -n "$PROXY_ADDR" ] && command -v wget >/dev/null 2>&1; then
        http_proxy="$PROXY_ADDR" https_proxy="$PROXY_ADDR" wget -qO "$2" --timeout=900 "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$2" --timeout=900 "$1"
    else
        log "ERROR: curl or wget is required"; set_status failed "no curl/wget"; exit 1
    fi
}

echo $$ > "$PID_FILE"

[ -x "$OF_BIN" ] && { log "binary already present at $OF_BIN"; set_status done "already installed"; exit 0; }

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)        BIN_LABEL="amd64" ;;
    aarch64|arm64) BIN_LABEL="arm64" ;;
    armv7l|armv7)  BIN_LABEL="armv7" ;;
    armv6l|armv6)  BIN_LABEL="armv6" ;;
    mipsel)        BIN_LABEL="mipsle" ;;
    mips)          BIN_LABEL="mips" ;;
    mips64el)      BIN_LABEL="mips64le" ;;
    *) log "Unsupported architecture: $ARCH"; set_status failed "unsupported arch $ARCH"; exit 1 ;;
esac

BASE="${OF_BIN_BASE:-}"
[ -n "$BASE" ] || BASE="$(uci -q get krot_openflux.settings.bin_base 2>/dev/null || true)"
BASE="${BASE%/}"

# Users often paste the release *page* URL from the browser; rewrite it to the
# download base so the asset URL resolves instead of 404-ing.
case "$BASE" in
    */releases/tag/*) BASE="$(printf '%s' "$BASE" | sed 's,/releases/tag/,/releases/download/,')" ;;
esac

[ -n "$BASE" ] || BASE="https://github.com/${OF_RELEASE_REPO}/releases/download/${OF_TAG}"

URL="${BASE}/openflux-linux-${BIN_LABEL}"
log "arch=$ARCH label=$BIN_LABEL proxy=${PROXY_ADDR:-none}"
set_status running "arch=$ARCH скачиваю $URL"

TMP="$(mktemp -d /tmp/openflux-fetch.XXXXXX 2>/dev/null || echo /tmp/openflux-fetch.$$)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

place_binary() {
    mkdir -p "$OF_DIR"
    mv "$TMP/openflux" "$OF_BIN" 2>/dev/null || cp "$TMP/openflux" "$OF_BIN"
    chmod 0755 "$OF_BIN"
}

log "downloading $URL"
if http_download "$URL" "$TMP/openflux" 2>/dev/null && [ -s "$TMP/openflux" ] && is_elf "$TMP/openflux"; then
    place_binary
    log "installed openflux-linux-${BIN_LABEL} from $BASE"
    set_status done "installed openflux-linux-${BIN_LABEL}"
else
    # Fallback: scan upstream releases for a matching asset.
    log "download from $URL failed; scanning ${UPSTREAM_RELEASE_REPO} releases..."
    set_status running "сканирую upstream-релизы"
    release_json="$(http_get "${GITHUB_API}/repos/${UPSTREAM_RELEASE_REPO}/releases?per_page=20" 2>/dev/null)" || release_json=""
    asset_url=""
    if [ -n "$release_json" ]; then
        asset_url="$(printf '%s\n' "$release_json" \
            | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*openflux-linux-'"${BIN_LABEL}"'"' \
            | head -1 | sed 's/^"browser_download_url"[[:space:]]*:[[:space:]]*"//;s/"$//')"
    fi
    if [ -n "$asset_url" ] && http_download "$asset_url" "$TMP/openflux" 2>/dev/null \
        && [ -s "$TMP/openflux" ] && is_elf "$TMP/openflux"; then
        place_binary
        log "installed openflux-linux-${BIN_LABEL} from upstream release"
        set_status done "installed from upstream release"
    else
        log "ERROR: could not download openflux-linux-${BIN_LABEL}"
        log "Check the internet connection, or host the binary and set bin_base."
        set_status failed "could not download openflux-linux-${BIN_LABEL}"
        exit 1
    fi
fi

if [ "${FETCH_RESTART:-0}" = "1" ]; then
    [ -x /opt/openflux/gen-state.sh ] && /opt/openflux/gen-state.sh >/dev/null 2>&1 || true
    /etc/init.d/krot-openflux restart >/dev/null 2>&1 || true
fi
FETCHSH
    chmod 0755 "$OF_DIR/fetch-binary.sh"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

install_config
cleanup_legacy_layout
install_webpanel
install_cgi
install_runner
install_state_gen
install_fetch_binary
install_init
install_binary

echo "$MODULE_VERSION" > "$OF_VERSION"

/etc/init.d/krot-openflux enable >/dev/null 2>&1 || true
/etc/init.d/krot-openflux restart >/dev/null 2>&1 || /etc/init.d/krot-openflux start >/dev/null 2>&1 || true

"$OF_DIR/gen-state.sh" >/dev/null 2>&1 || true

ROUTER_IP="$(uci -q get network.lan.ipaddr 2>/dev/null || echo '192.168.1.1')"

msg ""
msg "OpenFlux Exit Node installed successfully"
msg ""
msg "Web panel:   http://${ROUTER_IP}/openflux/"
msg "Config:      $OF_CONFIG"
msg "Service:     /etc/init.d/krot-openflux start|stop|restart"
msg ""
if [ -x "$OF_BIN" ]; then
    msg "openflux binary: $OF_BIN"
else
    msg "openflux binary is MISSING — the service stays stopped until it is in place."
    msg "Build it with hub/${MODULE_ID}/build-binaries.sh and copy to ${OF_BIN},"
    msg "or host it and set bin_base on the web panel, then press Update."
fi
msg ""
