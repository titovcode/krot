#!/bin/sh
# olcRTC tunnel (srv) installer for K.R.O.T. Hub
# Source: https://github.com/openlibrecommunity/olcrtc
#
# Installs olcrtc in server mode: the router acts as the tunnel exit on the
# free-internet side. Phones behind an allow-list connect to it through a
# video-call (SFU) room and get their traffic out through this router.
set -e

GITHUB_API="https://api.github.com"
TMP_DIR="$(mktemp -d /tmp/hub-olcrtc.XXXXXX 2>/dev/null || { mkdir -p /tmp/hub-olcrtc.$$; echo /tmp/hub-olcrtc.$$; })"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM

fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }
msg()  { printf '\033[32m%s\033[0m\n' "$1"; }

OLC_DIR="/opt/olcrtc"
OLC_BIN="$OLC_DIR/olcrtc"
OLC_CONFIG="/etc/config/olcrtc"
OLC_INIT="/etc/init.d/olcrtc"
OLC_YAML="/etc/olcrtc/server.yaml"
OLC_GEN_QR="$OLC_DIR/gen-qr.sh"
OLC_WWW_DIR="/www/olcrtc"
OLC_DATA_DIR="$OLC_DIR/data"

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

# Resolve the module source repo/branch (custom Hub source wins over default).
REPO="${OLCRTC_REPO:-$(uci -q get krot.hub_source_olcrtc.repo 2>/dev/null || true)}"
REPO="${REPO:-${PODKOP_RELEASE_REPO:-titovcode/krot}}"
BRANCH="${OLCRTC_BRANCH:-$(uci -q get krot.hub_source_olcrtc.branch 2>/dev/null || true)}"
BRANCH="${BRANCH:-main}"

# Detect architecture
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  OLC_ARCH="amd64" ;;
    aarch64) OLC_ARCH="arm64" ;;
    *)       fail "Unsupported architecture: $ARCH (module ships prebuilt amd64/arm64 binaries)" ;;
esac

# Generate a shared key (64 hex chars) and a random room id on first install.
gen_hex() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$1" 2>/dev/null
    else
        head -c "$1" /dev/urandom 2>/dev/null | hexdump -ve '1/1 "%02x"'
    fi
}

# ── 1. Binary ────────────────────────────────────────────────────────────
if [ -x "$OLC_BIN" ]; then
    msg "olcrtc binary already installed at $OLC_BIN"
elif [ -f /tmp/olcrtc ]; then
    msg "Installing manually placed binary from /tmp/olcrtc..."
    mkdir -p "$OLC_DIR"
    cp /tmp/olcrtc "$OLC_BIN" && chmod 0755 "$OLC_BIN"
else
    msg "Downloading olcrtc ($OLC_ARCH) from ${REPO} releases..."
    if [ -n "$OLCRTC_BINARY_URL" ]; then
        DOWNLOAD_URL="$OLCRTC_BINARY_URL"
    else
        # Explicit tag (not releases/latest) so this release never becomes
        # the "latest" K.R.O.T. release and breaks the update check.
        OLCRTC_TAG="${OLCRTC_TAG:-olcrtc-0.1.0}"
        DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${OLCRTC_TAG}/olcrtc-linux-${OLC_ARCH}"
    fi
    http_download "$DOWNLOAD_URL" "$TMP_DIR/olcrtc" || fail "Failed to download olcrtc from ${DOWNLOAD_URL}"
    [ -s "$TMP_DIR/olcrtc" ] || fail "Downloaded binary is empty"
    mkdir -p "$OLC_DIR"
    cp "$TMP_DIR/olcrtc" "$OLC_BIN" && chmod 0755 "$OLC_BIN"
fi

mkdir -p "$OLC_DATA_DIR"

# ── 2. Config (only on first install; existing config is preserved) ──────
if [ ! -f "$OLC_CONFIG" ]; then
    msg "Generating default /etc/config/olcrtc (random key and room)..."
    DEFAULT_KEY="$(gen_hex 32 || true)"
    [ -n "$DEFAULT_KEY" ] || fail "Failed to generate random key"
    ROOM_SUFFIX="$(gen_hex 4 || true)"
    [ -n "$ROOM_SUFFIX" ] || ROOM_SUFFIX="$(date +%s | tail -c 9)"
    cat > "$OLC_CONFIG" <<EOF
config settings 'settings'
	option enabled '1'
	option provider 'jitsi'
	option room_id 'https://meet.egovm.ru/olc${ROOM_SUFFIX}'
	option key '${DEFAULT_KEY}'
	option transport 'datachannel'
	option dns '1.1.1.1:53'
	option liveness_interval '30s'
	option liveness_timeout '30s'
	option liveness_failures '5'
EOF
    chmod 0600 "$OLC_CONFIG"
fi

# Fill in liveness options on an existing config (tolerate jittery SFU).
# A reinstall/update must not overwrite a user's room/key/transport.
if [ -f "$OLC_CONFIG" ] && command -v uci >/dev/null 2>&1; then
    for opt in liveness_interval:30s liveness_timeout:30s liveness_failures:5; do
        name="${opt%%:*}"; val="${opt#*:}"
        uci -q get "olcrtc.settings.${name}" >/dev/null 2>&1 || uci -q set "olcrtc.settings.${name}=${val}"
    done
    uci -q commit olcrtc 2>/dev/null || true
fi

# ── 3. QR page assets (downloaded from the same module repo) ─────────────
mkdir -p "$OLC_WWW_DIR"

if [ ! -f "$OLC_WWW_DIR/qrcode.js" ]; then
    msg "Downloading QR-code renderer..."
    http_download "https://raw.githubusercontent.com/${REPO}/${BRANCH}/hub/olcrtc/qrcode.js" \
        "$OLC_WWW_DIR/qrcode.js" \
        || fail "Failed to download qrcode.js (does your module repo contain hub/olcrtc/qrcode.js?)"
    chmod 0644 "$OLC_WWW_DIR/qrcode.js"
fi

# Static QR page (installed once; state.js is regenerated per config change)
cat > "$OLC_WWW_DIR/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>olcRTC tunnel</title>
<style>
  :root { color-scheme: dark; }
  body {
    margin: 0; padding: 24px 20px 40px;
    background: #0f1115; color: #e6e8eb;
    font-family: -apple-system, "Segoe UI", Roboto, Arial, sans-serif;
    display: flex; flex-direction: column; align-items: center;
  }
  h1 { font-size: 22px; margin: 4px 0 8px; }
  .sub { color: #9aa3ae; font-size: 14px; text-align: center; max-width: 420px; margin: 0 0 20px; }
  #qr { background: #fff; padding: 14px; border-radius: 12px; margin: 0 0 20px; }
  .link {
    background: #1a1e26; border: 1px solid #2c3340; border-radius: 8px;
    padding: 10px 12px; font-size: 12px; word-break: break-all;
    max-width: 480px; text-align: center; margin-bottom: 12px;
  }
  button {
    background: #3b82f6; color: #fff; border: 0; border-radius: 8px;
    padding: 10px 18px; font-size: 14px; cursor: pointer; margin-bottom: 28px;
  }
  .steps { max-width: 480px; font-size: 14px; line-height: 1.6; color: #c9d0d8; }
  .steps b { color: #fff; }
  code { color: #8fd3ff; }
</style>
</head>
<body>
  <h1>olcRTC туннель</h1>
  <p class="sub">Трафик телефона идёт через видеозвонок и выходит через этот роутер. Сканируй QR приложением <b>owenclave</b> (или olcbox/veil).</p>
  <div id="qr"></div>
  <div class="link"><code id="link"></code></div>
  <button onclick="copyLink()">Копировать ссылку</button>
  <div class="steps">
    <p><b>1.</b> Установи <code>owenclave</code> (Google Play / GitHub releases) или <code>olcbox</code>.</p>
    <p><b>2.</b> В приложении: Добавить — по QR/скан — отсканируй этот код (достаточно один раз, дома).</p>
    <p><b>3.</b> Нажми «Подключить». Работает в любой сети, где доступен видеозвонок.</p>
    <p>Один и тот же QR можно использовать на нескольких телефонах.</p>
  </div>
  <script src="/olcrtc/state.js"></script>
  <script src="/olcrtc/qrcode.js"></script>
  <script>
    var uri = window.OLCRTC_URI || '';
    document.getElementById('link').textContent = uri;
    if (uri && typeof qrcode !== 'undefined') {
      try {
        var qr = qrcode(0, 'M');
        qr.addData(uri);
        qr.make();
        document.getElementById('qr').innerHTML = qr.createImgTag(6, 8);
      } catch (e) {}
    }
    function copyLink() {
      if (navigator.clipboard) {
        navigator.clipboard.writeText(uri).then(function(){ alert('Ссылка скопирована'); });
      } else {
        var t = document.createElement('textarea');
        t.value = uri; document.body.appendChild(t);
        t.select(); document.execCommand('copy');
        document.body.removeChild(t); alert('Ссылка скопирована');
      }
    }
  </script>
</body>
</html>
HTML
chmod 0644 "$OLC_WWW_DIR/index.html"

# state.js generator (reads /etc/config/olcrtc, writes window.OLCRTC_URI)
cat > "$OLC_GEN_QR" <<'SH'
#!/bin/sh
# Regenerates /www/olcrtc/state.js (phone link + QR data) from /etc/config/olcrtc.
set -e

OLC_CONFIG="/etc/config/olcrtc"
STATE_JS="/www/olcrtc/state.js"
WWW_DIR="/www/olcrtc"

[ -f "$OLC_CONFIG" ] || exit 0

provider="$(uci -q get olcrtc.settings.provider 2>/dev/null || echo jitsi)"
room_id="$(uci -q get olcrtc.settings.room_id 2>/dev/null || true)"
key="$(uci -q get olcrtc.settings.key 2>/dev/null || true)"
transport="$(uci -q get olcrtc.settings.transport 2>/dev/null || echo datachannel)"

[ -n "$room_id" ] && [ -n "$key" ] || exit 0

uri="olcrtc://${provider}?${transport}@${room_id}#${key}\$olcrtc srv"

mkdir -p "$WWW_DIR"
{
    printf 'window.OLCRTC_URI = "'
    printf '%s' "$uri"
    printf '";\n'
} > "$STATE_JS"
chmod 0644 "$STATE_JS"
SH
chmod 0755 "$OLC_GEN_QR"

# ── 4. Service ───────────────────────────────────────────────────────────
cat > "$OLC_INIT" <<'SH'
#!/bin/sh /etc/rc.common
# shellcheck disable=SC2034,SC2154
# olcRTC tunnel exit (server mode) for K.R.O.T. Hub

START=90
STOP=10
USE_PROCD=1

OLC_BIN="/opt/olcrtc/olcrtc"
OLC_CONFIG="/etc/config/olcrtc"
OLC_YAML="/etc/olcrtc/server.yaml"
OLC_GEN_QR="/opt/olcrtc/gen-qr.sh"
OLC_DATA="/opt/olcrtc/data"

render_yaml() {
    [ -f "$OLC_CONFIG" ] || return 1

    config_load olcrtc
    config_get_bool enabled settings enabled 1
    config_get provider settings provider jitsi
    config_get room_id settings room_id ""
    config_get key settings key ""
    config_get transport settings transport datachannel
    config_get dns settings dns 1.1.1.1:53
    config_get socks_proxy_addr settings socks_proxy_addr ""
    config_get socks_proxy_port settings socks_proxy_port 0
    config_get liveness_interval settings liveness_interval 30s
    config_get liveness_timeout settings liveness_timeout 30s
    config_get liveness_failures settings liveness_failures 5

    [ "$enabled" -eq 1 ] || return 1
    [ -n "$room_id" ] || return 1
    [ -n "$key" ] || return 1

    mkdir -p "$(dirname "$OLC_YAML")" "$OLC_DATA"
    cat > "$OLC_YAML" <<EOF
mode: srv
auth:
  provider: ${provider}
room:
  id: "${room_id}"
crypto:
  key: "${key}"
net:
  transport: ${transport}
  dns: "${dns}"
socks:
  proxy_addr: "${socks_proxy_addr}"
  proxy_port: ${socks_proxy_port}
liveness:
  interval: ${liveness_interval}
  timeout: ${liveness_timeout}
  failures: ${liveness_failures}
data: ${OLC_DATA}
debug: false
EOF
    chmod 0600 "$OLC_YAML"
    return 0
}

start_service() {
    render_yaml || return 1
    [ -x "$OLC_BIN" ] || return 1

    # Refresh the phone QR page for the current config.
    [ -x "$OLC_GEN_QR" ] && "$OLC_GEN_QR" >/dev/null 2>&1 || true

    procd_open_instance
    procd_set_param command "$OLC_BIN" "$OLC_YAML"
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    procd_kill "$NAME" 2>/dev/null || true
}

reload_service() {
    render_yaml
}

service_triggers() {
    procd_add_reload_trigger "olcrtc"
}
SH
chmod 0755 "$OLC_INIT"

# ── 5. Start ─────────────────────────────────────────────────────────────
"$OLC_GEN_QR" >/dev/null 2>&1 || true

/etc/init.d/olcrtc enable 2>/dev/null || true
# restart (not start): a re-run after an update must apply the new config.
/etc/init.d/olcrtc restart 2>/dev/null || /etc/init.d/olcrtc start 2>/dev/null || true

ROUTER_IP="$(uci get network.lan.ipaddr 2>/dev/null || echo '192.168.1.1')"

msg ""
msg "olcRTC tunnel installed successfully"
msg ""
msg "Server mode (srv):"
msg "  Config:  $OLC_CONFIG (provider, room_id, key, transport)"
msg "  Service: /etc/init.d/olcrtc start|stop|restart"
msg ""
msg "Phone connection:"
msg "  QR page:   http://${ROUTER_IP}/olcrtc/"
msg "  Scan it in owenclave / olcbox once (from home), then connect from any network."
msg ""
msg "Notes:"
msg "  - The default room uses the Jitsi instance meet.egovm.ru. If it is not"
msg "    reachable in your network, change room_id in $OLC_CONFIG"
msg "    (see https://github.com/openlibrecommunity/olcrtc docs/examples/jitsi.instances.yaml)"
msg "    and run: /etc/init.d/olcrtc restart"
msg "  - The key and room must stay the same on every client phone."
