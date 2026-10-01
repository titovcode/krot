# shellcheck disable=SC2034

PODKOP_VERSION="__COMPILED_VERSION_VARIABLE__"
PODKOP_CONFIG_NAME="krot"
PODKOP_CONFIG="/etc/config/$PODKOP_CONFIG_NAME"
PODKOP_BIN="/usr/bin/krot"
PODKOP_SERVICE_NAME="krot"
PODKOP_SERVICE_INIT="/etc/init.d/krot"
PODKOP_RELEASE_REPO="titovcode/krot"
PODKOP_LUCI_VIEW_NAMESPACE="krot"
PODKOP_LUCI_VIEW_DIR="/www/luci-static/resources/view/$PODKOP_LUCI_VIEW_NAMESPACE"
PODKOP_LUCI_I18N_DOMAIN="krot"
PODKOP_DNSMASQ_SECTION="krot"
## Common
RESOLV_CONF="/etc/resolv.conf"
CHECK_PROXY_IP_DOMAIN="ip.podkop.fyi"
FAKEIP_TEST_DOMAIN="fakeip.podkop.fyi"
TMP_SING_BOX_FOLDER="/tmp/sing-box"
TMP_RULESET_FOLDER="$TMP_SING_BOX_FOLDER/rulesets"
TMP_SUBSCRIPTION_FOLDER="$TMP_SING_BOX_FOLDER/subscriptions"
CLOUDFLARE_OCTETS="8.47 162.159 188.114" # Endpoints https://github.com/ampetelin/warp-endpoint-checker
COREUTILS_BASE64_REQUIRED_VERSION="9.7"
RT_TABLE_NAME="krot"

## nft
NFT_TABLE_NAME="KrotTable"
NFT_LOCALV4_SET_NAME="localv4"
NFT_COMMON_SET_NAME="krot_subnets"
NFT_PORT_SET_NAME="krot_ports"
NFT_IP_PORT_SET_NAME="krot_ip_ports"
NFT_DISCORD_SET_NAME="krot_discord_subnets"
NFT_INTERFACE_SET_NAME="krot_interfaces"
NFT_FAKEIP_MARK="0x00100000"
NFT_OUTBOUND_MARK="0x00200000"
# Base bit (22) is disjoint from the fakeip (bit 20) and outbound (bit 21) marks
# so VPN marks (base + section index) never match the proxy chain's
# "meta mark & 0x00100000 == 0x00100000" TProxy rule.
NFT_VPN_MARK_BASE="0x00400000"
NFT_VPN_RT_TABLE_BASE=1000

# Egress mark/route table used to bind a sidecar proxy (Xray) process to a
# tunnel. A sidecar runs as a local process, so its own upstream connection
# carries no K.R.O.T. source-IP mark and would leave through the plain WAN,
# which fails whenever the proxy server is only reachable inside a tunnel.
# Base bit (23) stays disjoint from the fakeip/outbound/VPN marks above.
NFT_SIDECAR_EGRESS_MARK="0x00800000"
NFT_SIDECAR_EGRESS_RT_TABLE=1099

## sing-box
SB_REQUIRED_VERSION="1.12.0"
# DNS
SB_DNS_SERVER_TAG="dns-server"
SB_FAKEIP_DNS_SERVER_TAG="fakeip-server"
SB_FAKEIP_INET4_RANGE="198.18.0.0/15"
SB_BOOTSTRAP_SERVER_TAG="bootstrap-dns-server"
SB_FAKEIP_DNS_RULE_TAG="fakeip-dns-rule-tag"
SB_FAKEIP_RULESET_DNS_RULE_TAG="fakeip-ruleset-dns-rule-tag"
SB_SERVICE_FAKEIP_DNS_RULE_TAG="service-fakeip-dns-rule-tag"
# Inbounds
SB_TPROXY_INBOUND_TAG="tproxy-in"
SB_TPROXY_INBOUND_ADDRESS="127.0.0.1"
SB_TPROXY_INBOUND_PORT=1602
SB_DNS_INBOUND_TAG="dns-in"
SB_DNS_INBOUND_ADDRESS="127.0.0.42"
SB_DNS_INBOUND_PORT=53
SB_SERVICE_MIXED_INBOUND_TAG="service-mixed-in"
SB_SERVICE_MIXED_INBOUND_ADDRESS="127.0.0.1"
SB_SERVICE_MIXED_INBOUND_PORT=4534
# Outbounds
SB_DIRECT_OUTBOUND_TAG="direct-out"
# Experimental
SB_CLASH_API_CONTROLLER_PORT=9090

## Lists
GITHUB_RAW_URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main"
SRS_MAIN_URL="https://github.com/itdoginfo/allow-domains/releases/latest/download"
SRS_ADS_HAGEZI_PRO_URL="https://github.com/zxc-rv/ad-filter/releases/latest/download/adlist.srs"
SRS_SUPERCELL_URL="https://raw.githubusercontent.com/ushan0v/sing-box-supercell-ruleset/main/supercell.srs"
SUBNETS_TWITTER="${GITHUB_RAW_URL}/Subnets/IPv4/twitter.lst"
SUBNETS_META="${GITHUB_RAW_URL}/Subnets/IPv4/meta.lst"
SUBNETS_DISCORD="${GITHUB_RAW_URL}/Subnets/IPv4/discord.lst"
SUBNETS_ROBLOX="${GITHUB_RAW_URL}/Subnets/IPv4/roblox.lst"
SUBNETS_TELEGRAM="${GITHUB_RAW_URL}/Subnets/IPv4/telegram.lst"
SUBNETS_CLOUDFLARE="${GITHUB_RAW_URL}/Subnets/IPv4/cloudflare.lst"
SUBNETS_HETZNER="${GITHUB_RAW_URL}/Subnets/IPv4/hetzner.lst"
SUBNETS_OVH="${GITHUB_RAW_URL}/Subnets/IPv4/ovh.lst"
SUBNETS_DIGITALOCEAN="${GITHUB_RAW_URL}/Subnets/IPv4/digitalocean.lst"
SUBNETS_CLOUDFRONT="${GITHUB_RAW_URL}/Subnets/IPv4/cloudfront.lst"
COMMUNITY_SERVICES="russia_inside russia_outside ukraine_inside geoblock block porn news anime youtube hdrezka tiktok google_ai google_play hodca discord meta twitter cloudflare cloudfront digitalocean hetzner ovh telegram roblox ads_hagezi_pro supercell"

## Zapret
ZAPRET_PROVIDER_BASE_DIR="/opt/zapret"
ZAPRET_PROVIDER_NFQWS_BIN="$ZAPRET_PROVIDER_BASE_DIR/nfq/nfqws"
ZAPRET_PROVIDER_FILES_DIR="$ZAPRET_PROVIDER_BASE_DIR/files"
ZAPRET_PROVIDER_IPSET_DIR="$ZAPRET_PROVIDER_BASE_DIR/ipset"
ZAPRET_LEGACY_RUNTIME_BASE_DIR="/var/run/krot/zapret-runtime"
ZAPRET_NFQWS_BIN="$ZAPRET_PROVIDER_NFQWS_BIN"
ZAPRET_STATE_DIR="/var/run/krot/zapret"
ZAPRET_PID_DIR="$ZAPRET_STATE_DIR/pid"
ZAPRET_CHILD_PID_DIR="$ZAPRET_STATE_DIR/child-pid"
ZAPRET_LOG_DIR="$ZAPRET_STATE_DIR/log"
ZAPRET_HOSTLIST_DIR="$ZAPRET_STATE_DIR/hostlist"
ZAPRET_ROUTE_MARK_BASE="0x01000000"
# K.R.O.T. uses a dedicated NFQUEUE range so its managed nfqws processes can
# coexist with standalone zapret/luci-app-zapret instances on the same router.
ZAPRET_QUEUE_BASE=4000
ZAPRET_QUEUE_RANGE_SIZE=256
ZAPRET_NFQWS_RESPAWN_DELAY=5
# How long to wait for a provider to bind its NFQUEUE before calling the start
# failed. zapret2 loads a Lua desync engine before binding, so this has to be
# generous compared with the classic binary's near-instant start.
ZAPRET_START_TIMEOUT=8
ZAPRET_DESYNC_MARK="0x40000000"
ZAPRET_DESYNC_MARK_POSTNAT="0x20000000"
ZAPRET_LEGACY_DEFAULT_NFQWS_OPT="--filter-tcp=80 <HOSTLIST> --dpi-desync=fake,fakedsplit --dpi-desync-autottl=2 --dpi-desync-fooling=badsum --new --filter-tcp=443 --hostlist=/opt/zapret/ipset/zapret-hosts-google.txt --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=11 --dpi-desync-fooling=badsum --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com --new --filter-udp=443 --hostlist=/opt/zapret/ipset/zapret-hosts-google.txt --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-fake-quic=/opt/zapret/files/fake/quic_initial_www_google_com.bin --new --filter-udp=443 <HOSTLIST_NOAUTO> --dpi-desync=fake --dpi-desync-repeats=11 --new --filter-tcp=443 <HOSTLIST> --dpi-desync=multidisorder --dpi-desync-split-pos=1,sniext+1,host+1,midsld-2,midsld,midsld+2,endhost-1"
ZAPRET_DEFAULT_NFQWS_OPT="--filter-tcp=80 --dpi-desync=fake,fakedsplit --dpi-desync-autottl=2 --dpi-desync-fooling=badsum --new --filter-tcp=443 --dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-repeats=11 --dpi-desync-fooling=badsum --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com --new --filter-udp=443 --dpi-desync=fake --dpi-desync-repeats=11 --dpi-desync-fake-quic=/opt/zapret/files/fake/quic_initial_www_google_com.bin"
# Zapret2 (bol-van/zapret2) ships "nfqws2" as the provider binary under the same
# /opt/zapret path. It is not a drop-in replacement for the classic nfqws: the
# whole desync engine moved from C options into Lua, so every "--dpi-desync*"
# option above is rejected as "unrecognized" and even "--dpi-desync=fake" is
# gone. nfqws2 also renamed the mark option to "--fwmark" and has no
# "--dpi-desync-fwmark" at all.
#
# On nfqws2 the strategy is therefore expressed through the upstream Lua
# profiles, invoked exactly the way upstream's own init script does it
# (init.d/openwrt/zapret2: LUAOPT + NFQWS2_OPT_BASE). zapret-lib provides the
# desync primitives, zapret-antidpi the per-protocol techniques, and
# zapret-auto the per-host orchestration that picks a technique and caches it -
# which is the behaviour the classic hand-written strategies approximated.
ZAPRET_LUA_DIR="$ZAPRET_PROVIDER_BASE_DIR/lua"
ZAPRET_NFQWS2_LUA_INIT="--lua-init=@$ZAPRET_LUA_DIR/zapret-lib.lua --lua-init=@$ZAPRET_LUA_DIR/zapret-antidpi.lua --lua-init=@$ZAPRET_LUA_DIR/zapret-auto.lua"
# Baseline filters; the desync behaviour itself comes from the Lua profiles
# above. "--filter-tcp=443 --filter-udp=443" mirrors the ports the classic
# default strategy acted on.
ZAPRET_NFQWS2_DEFAULT_OPT="--filter-tcp=443 --filter-udp=443"

## ByeDPI
BYEDPI_BIN="/usr/bin/ciadpi"
BYEDPI_SERVICE_INIT="/etc/init.d/byedpi"
BYEDPI_STATE_DIR="/var/run/krot/byedpi"
BYEDPI_PID_DIR="$BYEDPI_STATE_DIR/pid"
BYEDPI_CHILD_PID_DIR="$BYEDPI_STATE_DIR/child-pid"
BYEDPI_LOG_DIR="$BYEDPI_STATE_DIR/log"
BYEDPI_LISTEN_ADDRESS="127.0.0.1"
BYEDPI_PORT_BASE=1080
BYEDPI_RESPAWN_DELAY=5
BYEDPI_OPEN_FILES_LIMIT=4096
BYEDPI_DEFAULT_CMD_OPTS="-o 2 --auto=t,r,a,s -d 2"
