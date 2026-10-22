#!/bin/sh
# AdGuard Home installer for K.R.O.T. Hub
# Source: https://github.com/AdguardTeam/AdGuardHome
set -e

GITHUB_API="https://api.github.com"
TMP_DIR="$(mktemp -d /tmp/hub-adguard.XXXXXX 2>/dev/null || { mkdir -p /tmp/hub-adguard.$$; echo /tmp/hub-adguard.$$; })"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM

fail() { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }
msg()  { printf '\033[32m%s\033[0m\n' "$1"; }

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

# Detect architecture
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  AG_ARCH="amd64" ;;
    aarch64) AG_ARCH="arm64" ;;
    armv7*)  AG_ARCH="armv7" ;;
    mipsel*) AG_ARCH="mipsle" ;;
    mips*)   AG_ARCH="mips" ;;
    *)       fail "Unsupported architecture: $ARCH" ;;
esac

# Detect OS
AG_PLATFORM="linux"

# Check if already installed
if [ -x /opt/AdGuardHome/AdGuardHome ]; then
    INSTALLED_VERSION="$(/opt/AdGuardHome/AdGuardHome --version 2>/dev/null | head -1 || true)"
    msg "AdGuard Home already installed: ${INSTALLED_VERSION:-unknown}"
    msg "Updating..."
fi

msg "Fetching latest AdGuard Home release..."
RELEASE_JSON="$(http_get "${GITHUB_API}/repos/AdguardTeam/AdGuardHome/releases/latest")" \
    || fail "Failed to fetch release info from GitHub"

[ -n "$RELEASE_JSON" ] || fail "Empty response from GitHub API"

# Find matching asset
DOWNLOAD_URL="$(printf '%s\n' "$RELEASE_JSON" | grep -o "\"browser_download_url\"[[:space:]]*:[[:space:]]*\"[^\"]*_${AG_PLATFORM}_${AG_ARCH}.tar.gz\"" | head -1 | sed 's/^"browser_download_url"[[:space:]]*:[[:space:]]*"//;s/"$//')"

[ -n "$DOWNLOAD_URL" ] || fail "No AdGuard package found for ${AG_PLATFORM}/${AG_ARCH}"

msg "Downloading AdGuard Home..."
http_download "$DOWNLOAD_URL" "$TMP_DIR/adguard.tar.gz" || fail "Download failed"
[ -s "$TMP_DIR/adguard.tar.gz" ] || fail "Downloaded file is empty"

# Stop existing service if running
if [ -x /opt/AdGuardHome/AdGuardHome ]; then
    msg "Stopping existing AdGuard Home..."
    /opt/AdGuardHome/AdGuardHome -s stop 2>/dev/null || true
fi

# Extract
msg "Extracting..."
mkdir -p /opt/AdGuardHome
tar -xzf "$TMP_DIR/adguard.tar.gz" -C /opt/ 2>/dev/null \
    || tar -xzf "$TMP_DIR/adguard.tar.gz" --strip-components=1 -C /opt/AdGuardHome 2>/dev/null \
    || fail "Failed to extract AdGuard Home"

chmod +x /opt/AdGuardHome/AdGuardHome 2>/dev/null || true

# Pre-seed AdGuardHome config so it binds to 127.0.0.1:5353 (NOT :53 —
# dnsmasq already binds :53, and we don't want to fight it). K.R.O.T. uses
# 127.0.0.42 for its own DNS inbound, so 5353 is free.
#
# We pass dns_server=127.0.0.1#5353 below to sing-box so it talks to AdGuard
# on the alternate port. AdGuard will not start the setup wizard if
# AdGuardHome.yaml already exists with valid auth.
CONFIG_FILE="/opt/AdGuardHome/AdGuardHome.yaml"
if [ ! -f "$CONFIG_FILE" ]; then
    msg "Pre-seeding AdGuard Home config (bind 127.0.0.1:5353)..."
    cat > "$CONFIG_FILE" <<'YAML'
# Tell AdGuard Home this config is already at schema version 34 so it
# skips the migration step. The migration is what corrupts block-style
# lists like bootstrap_dns (rewrites them as "- - 1.1.1.1").
schema_version: 34
http:
  address: 0.0.0.0:3000
  session_ttl: 720h0m0s
users: []
auth_attempts: 5
upstream_dns:
  - https://1.1.1.1/dns-query
  - https://1.0.0.1/dns-query
  - tls://1.1.1.1
upstream_mode: load_balance
filtering:
  filtering_enabled: true
  filters_update_interval: 24
  blocking_mode: default
  blocked_response_ttl: 10
dns:
  bind_hosts:
    - 127.0.0.1
  port: 5353
  anonymize_client_ip: false
  ratelimit: 20
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
    - https://1.1.1.1/dns-query
    - https://1.0.0.1/dns-query
    - tls://1.1.1.1
  fallback_dns:
    - tls://1.0.0.1
  upstream_mode: load_balance
  fastest_timeout: 1s
  # Use Cloudflare (1.1.1.1) as bootstrap to resolve DoH/DoT hostnames
  # before the encrypted upstream is reachable. Without this, AdGuard
  # cannot dial "1.1.1.1" by name when upstream_dns uses https:// or tls://.
  #
  # NOTE: use flow-style list here. AdGuard Home v0.107 has a bug where
  # a block-style bootstrap_dns list is rewritten as a nested list
  # ("- - 1.1.1.1") on first startup, which then fails to parse and the
  # daemon crash-loops. The inline form survives the round-trip.
  # See https://github.com/AdguardTeam/AdGuardHome/issues/4067
  bootstrap_dns: ["1.1.1.1", "1.0.0.1"]
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  trusted_proxies:
    - 127.0.0.0/8
    - ::1/128
  cache_enabled: true
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: false
  cache_optimistic_answer_ttl: 30s
  cache_optimistic_max_age: 12h0m0s
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  max_goroutines: 300
  handle_ddr: true
  ipset_file: ""
  querylog_enabled: true
  querylog_file_enabled: true
  querylog_size_memory: 1000
  log_enabled: true
  log_file: ""
  log_size_memory: 4000
  verbose: false
  statistics_interval: 1
  protection_enabled: true
  dns64_prefixes: []
  dnssec_enabled: false
tls:
  enabled: false
  server_name: ""
  force_https: false
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 853
  port_dnscrypt: 0
  allow_unencrypted_doh: false
querylog:
  enabled: true
  interval: 168h0m0s
  size_memory: 1000
statistics:
  enabled: true
  interval: 24h0m0s
  size_memory: 1000
YAML
    # Make the config read-only. AdGuard Home v0.107 rewrites the YAML on
    # first start and corrupts block-style lists such as bootstrap_dns
    # (turns "- 1.1.1.1" into "- - 1.1.1.1"), which then crash-loops the
    # daemon. AdGuard logs a warning about the unwritable file but still
    # starts and serves normally. Users can still edit settings via the
    # web UI by manually running: chmod 0644 $CONFIG_FILE
    chmod 0444 "$CONFIG_FILE"
fi

# avahi-daemon (mDNS/Bonjour) binds UDP port 5353 on OpenWrt by default.
# That collides with AdGuard Home's own 5353 listener, so we must stop and
# disable avahi before starting AdGuard. mDNS is rarely used on a home
# router; users who need it can re-enable it after moving AdGuard to a
# different port.
if [ -x /etc/init.d/avahi-daemon ]; then
    msg "Stopping avahi-daemon (frees UDP port 5353 for AdGuard)..."
    /etc/init.d/avahi-daemon stop 2>/dev/null || true
    /etc/init.d/avahi-daemon disable 2>/dev/null || true
fi
# In case avahi is already running but the init script is missing
killall avahi-daemon 2>/dev/null || true

# Install as service (create init script manually - AdGuard's -s install
# creates /etc/init.d/AdGuardHome which may conflict and doesn't work reliably
# on all OpenWrt versions)
msg "Installing AdGuard Home service..."
cat > /etc/init.d/adguardhome << 'INITEOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10

USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /opt/AdGuardHome/AdGuardHome -s run
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    /opt/AdGuardHome/AdGuardHome -s stop 2>/dev/null || true
}
INITEOF
chmod +x /etc/init.d/adguardhome
/etc/init.d/adguardhome enable 2>/dev/null || true
/etc/init.d/adguardhome start 2>/dev/null || true

# Wait briefly for AdGuard to come up so the next UCI reload can pick it up
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if netstat -tln 2>/dev/null | grep -q ':5353 '; then
        break
    fi
    sleep 1
done

# Configure K.R.O.T. to use AdGuard as its upstream DNS.
# Use 127.0.0.1:5353 (NOT :53) so sing-box dials the alternate port.
# :53 is already bound by dnsmasq and we don't want to fight it.
#
# We force dns_type=udp on install. AdGuard listens on plain UDP/5353 by
# default, and this is the documented "install AdGuard via Hub" wiring: sing-box
# talks to AdGuard on UDP, and AdGuard forwards to Cloudflare DoH/DoT
# (configured further down in this file). The user can still flip dns_type to
# dot/doh in K.R.O.T. Settings afterwards if they want a different transport.
if command -v uci >/dev/null 2>&1; then
    msg "Pointing K.R.O.T. DNS to AdGuard (127.0.0.1:5353, udp)..."
    # Remember the user's previous DNS settings so remove.sh can restore them.
    PREV_DNS_SERVER="$(uci -q get krot.settings.dns_server 2>/dev/null || true)"
    PREV_DNS_TYPE="$(uci -q get krot.settings.dns_type 2>/dev/null || true)"
    # Save previous DNS only if not already saved (prevents overwriting on reinstall)
    if [ -z "$(uci -q get krot.settings.adguard_prev_dns_server 2>/dev/null)" ]; then
        uci -q set krot.settings.adguard_prev_dns_server="$PREV_DNS_SERVER"
        uci -q set krot.settings.adguard_prev_dns_type="$PREV_DNS_TYPE"
    fi
    uci -q set krot.settings.dns_server='127.0.0.1:5353'
    uci -q set krot.settings.dns_type='udp'
    uci -q commit krot
    # K.R.O.T. will be restarted by the Hub installer (updater.sh) so sing-box
    # picks up the new dns_server / dns_type. No restart here.
fi

ROUTER_IP="$(uci get network.lan.ipaddr 2>/dev/null || echo '192.168.1.1')"

# Remember which release was actually installed so K.R.O.T.'s Hub can report
# the real version (a VERSION file beats parsing --version output).
ADG_TAG="$(printf '%s\n' "$RELEASE_JSON" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//;s/"$//')"
echo "${ADG_TAG#v}" > /opt/AdGuardHome/VERSION

msg "AdGuard Home installed successfully"
msg ""
msg "Web interface: http://${ROUTER_IP}:3000 (configure filters, users, etc.)"
msg "DNS:           127.0.0.1:5353 (consumed by K.R.O.T. sing-box)"
msg ""
msg "K.R.O.T. now routes all DNS through AdGuard for filtering."
