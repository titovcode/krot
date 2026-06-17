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

# Pre-seed AdGuardHome config so it binds to 127.0.0.1:53 — that way K.R.O.T.
# (which uses 127.0.0.42:53) and AdGuard can coexist on the same router.
# AdGuard will not start the web UI setup wizard if AdGuardHome.yaml already
# exists with valid auth.
CONFIG_FILE="/opt/AdGuardHome/AdGuardHome.yaml"
if [ ! -f "$CONFIG_FILE" ]; then
    msg "Pre-seeding AdGuard Home config (bind 127.0.0.1:53)..."
    cat > "$CONFIG_FILE" <<'YAML'
http:
  address: 0.0.0.0:3000
users: []
auth_attempts: 5
blocklist_client_rules: []
blocklist_disabled: false
upstream_dns:
  - 1.1.1.1
  - 8.8.8.8
upstream_dns_file: ""
upstream_mode: load_balance
filtering:
  filtering_enabled: true
  filters_update_interval: 24
  blocking_mode: default
  blocked_response_ttl: 10
  protection_enabled: true
  protection_disabled_until: null
  parental_enabled: false
  safebrowsing_enabled: false
  safesearch_enabled: false
  safesearch_disabled_until: null
  safe_dns_enabled: false
  safe_dns_provider: ""
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_services:
    schedule:
      time_zone: Local
  parental_blocked_services: []
  safebrowsing_blocked_services: []
  safe_dns_blocked_services: []
dns:
  bind_host: 127.0.0.1
  port: 53
  anonymize_client_ip: false
  protection_enabled: true
  ratelimit: 20
  ratelimit_subnet_len: 24
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
    - 1.1.1.1
    - 8.8.8.8
  upstream_dns_file: ""
  bootstrap_dns:
    - 9.9.9.10
    - 149.112.112.10
  fallback_dns:
    - 1.0.0.1
    - 8.8.4.4
  upstream_mode: load_balance
  fastest_ip_addr: false
  access_list: []
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  trusted_proxies: []
  dns64_prefixes: []
  dnssec_enabled: false
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  max_goroutines: 300
  handle_ddr: true
  ipset_file: ""
  querylog_enabled: true
  querylog_file_enabled: true
  querylog_interval: 2160h
  querylog_size_memory: 1000
  log_enabled: true
  log_file: ""
  log_interval: 24h
  log_size_memory: 4000
  verbose: false
  statistics_interval: 1
tls:
  enabled: false
  server_name: ""
  force_https: false
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 853
  port_dnscrypt: 0
  dnscrypt_config_file: ""
  allow_unencrypted_doh: false
  strict_sni_check: false
  certificate_chain: ""
  private_key: ""
  certificate_path: ""
  private_key_path: ""
  ocsp_response: ""
  ocsp_stapling: false
  dnsip_edns: ""
  upstream_mode: load_balance
  cipher_list: ""
  curve_preferences: ""
  support_plain_dns: true
  config_override: ""
querylog:
  enabled: true
  file_enabled: true
  interval: 2160h
  size_memory: 1000
statistics:
  enabled: true
  interval: 1
  size_memory: 1000
web_session_ttl: 720h
YAML
    chmod 0644 "$CONFIG_FILE"
fi

# Install as service
msg "Installing AdGuard Home service..."
/opt/AdGuardHome/AdGuardHome -s install 2>/dev/null || true
/opt/AdGuardHome/AdGuardHome -s start 2>/dev/null || true

# Wait briefly for AdGuard to come up so the next UCI reload can pick it up
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if /opt/AdGuardHome/AdGuardHome -s status 2>/dev/null | grep -q 'running'; then
        break
    fi
    sleep 1
done

# Configure K.R.O.T. to use AdGuard as its upstream DNS
if command -v uci >/dev/null 2>&1; then
    msg "Pointing K.R.O.T. DNS to AdGuard (127.0.0.1)..."
    uci -q set krot.settings.dns_server='127.0.0.1'
    uci -q commit krot
    /etc/init.d/krot reload 2>/dev/null || /etc/init.d/krot restart 2>/dev/null || true
fi

ROUTER_IP="$(uci get network.lan.ipaddr 2>/dev/null || echo '192.168.1.1')"

msg "AdGuard Home installed successfully"
msg ""
msg "Web interface: http://${ROUTER_IP}:3000 (configure filters, users, etc.)"
msg "DNS:           127.0.0.1:53 (consumed by K.R.O.T. sing-box)"
msg ""
msg "K.R.O.T. now routes all DNS through AdGuard for filtering."
