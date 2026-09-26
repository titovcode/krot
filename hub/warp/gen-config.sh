#!/bin/sh
# hub/warp/gen-config.sh — генератор конфига Xray для одного WARP-профиля.
#
#   gen-config.sh [section]        # по умолчанию section=warp
#
# Значения берутся из UCI `krot_warp.<section>.<опция>`; переменные окружения
# WARP_<ОПЦИЯ> имеют приоритет (удобно для тестов без UCI). Результат — JSON в
# stdout, без jq/python (только busybox/POSIX sh).
#
# Схема повторяет проверенный конфиг WARP+noise:
#   outbound wireguard(warp) --streamSettings.sockopt.dialerProxy--> freedom(noise-out)
#   freedom(noise-out).settings.noises = [hex QUIC-мимикрия, N × rand]
# Нюансы Xray, которые здесь учтены:
#   * WG-outbound требует IP-цели -> settings.remoteDNS (DNS идёт внутри туннеля);
#   * WG-outbound по умолчанию поднимает свой kernel-TUN (IPv6-таблица 10230) ->
#     noKernelTun=1 по умолчанию, иначе второй инстанс/outbound не подключится;
#   * ключи из Cloudflare API/wgcf почти всегда требуют ненулевой settings.reserved;
#   * inbound `tun` есть только в Xray >= 26 (в 25.1.30 его нет) — проверяйте
#     `xray -test -c` в раннере, а не доверяйте генератору;
#   * `noises` в Xray не применяется к порту 53 (by design) — DNS не шумится.
#
# Зависимость от dash отсутствует: используются подстановки ${v//pat/rep} (ash/bash),
# как в krot/files/usr/lib/updater.sh.
set -u

SECTION="${1:-warp}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- константы Cloudflare WARP ------------------------------------------------
DEFAULT_PEER_PUBLIC_KEY='bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo='
DEFAULT_ENDPOINT='162.159.192.1:500'
# Дефолтный hex-шум (поддельный QUIC Initial) лежит рядом в noise-quic.hex;
# install.sh засевает его в UCI, но генератор умеет прочитать и файл напрямую.
NOISE_HEX_FILE="${WARP_NOISE_HEX_FILE:-${SCRIPT_DIR}/noise-quic.hex}"

warn() { printf '%s\n' "gen-config: $*" >&2; }
die()  { printf '%s\n' "gen-config: ERROR: $*" >&2; exit 1; }

# --- чтение значений ---------------------------------------------------------
# Путь к UCI-конфигу; переопределяется для тестов (KROT_WARP_UCI=/tmp/krot_warp).
UCI_CONFIG_FILE="${KROT_WARP_UCI:-/etc/config/krot_warp}"

uci_get() {
    command -v uci >/dev/null 2>&1 || return 0
    [ -f "$UCI_CONFIG_FILE" ] || return 0
    uci -q get "krot_warp.${SECTION}.$1" 2>/dev/null || true
}

env_get() {
    # $1 — имя переменной окружения (наши собственные имена, eval безопасен)
    eval "printf '%s' \"\${$1:-}\""
}

# UCI не отличает пустое значение от отсутствующего, поэтому «выключено» у нас
# задаётся явно: off / none / no / - . Пустая строка = «не задано» = дефолт.
off_marker() {
    case "$1" in
        off|OFF|none|NONE|no|NO|-) printf '' ;;
        *) printf '%s' "$1" ;;
    esac
}

opt() {
    # $1 = uci-опция, $2 = env-суффикс (WARP_<суффикс>), $3 = дефолт
    local v
    v="$(uci_get "$1")"
    [ -n "$v" ] || v="$(env_get "WARP_$2")"
    [ -n "$v" ] || v="$3"
    printf '%s' "$v"
}

trim() {
    local v="$1"
    while [ "${v# }" != "$v" ]; do v="${v# }"; done
    while [ "${v% }" != "$v" ]; do v="${v% }"; done
    printf '%s' "$v"
}

json_escape() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    printf '%s' "$v"
}

json_array_from_csv() {
    # "1.1.1.1, 1.0.0.1" -> "\"1.1.1.1\", \"1.0.0.1\""
    local csv="$1" out='' item oldifs
    oldifs="$IFS"; IFS=','
    for item in $csv; do
        item="$(trim "$item")"
        [ -n "$item" ] || continue
        [ -z "$out" ] || out="$out, "
        out="$out\"$(json_escape "$item")\""
    done
    IFS="$oldifs"
    printf '%s' "$out"
}

need_num() {
    # $1 = имя, $2 = значение, $3 = min, $4 = max
    case "$2" in
        ''|*[!0-9]*) die "$1 must be a non-negative number, got '$2'" ;;
    esac
    if [ "$2" -lt "$3" ] || [ "$2" -gt "$4" ]; then
        die "$1 is out of range [$3..$4]: $2"
    fi
}

bool_json() { [ "$1" = "1" ] && printf 'true' || printf 'false'; }

default_noise_hex() {
    [ -r "$NOISE_HEX_FILE" ] || return 0
    tr -d ' \t\r\n' < "$NOISE_HEX_FILE" 2>/dev/null || true
}

# --- значения профиля --------------------------------------------------------
private_key="$(opt private_key PRIVATE_KEY '')"
addresses="$(opt addresses ADDRESSES '')"
peer_public_key="$(opt peer_public_key PEER_PUBLIC_KEY "$DEFAULT_PEER_PUBLIC_KEY")"
endpoint="$(opt endpoint ENDPOINT "$DEFAULT_ENDPOINT")"
mtu="$(opt mtu MTU 1280)"
reserved_csv="$(opt reserved RESERVED '0,0,0')"
keepalive="$(opt keepalive KEEPALIVE 5)"
no_kernel_tun="$(opt no_kernel_tun NO_KERNEL_TUN 1)"
listen_host="$(opt listen_host LISTEN_HOST 127.0.0.1)"
listen_port="$(opt listen_port LISTEN_PORT 11080)"
http_port="$(opt http_port HTTP_PORT 11089)"
remote_dns="$(off_marker "$(opt remote_dns REMOTE_DNS '1.1.1.1,1.0.0.1')")"
dns_servers="$(off_marker "$(opt dns_servers DNS_SERVERS '1.1.1.1,1.0.0.1')")"
noise_enabled_raw="$(opt noise_enabled NOISE_ENABLED 1)"
case "$noise_enabled_raw" in
    0|off|OFF|no|NO|false|FALSE) noise_enabled=0 ;;
    *) noise_enabled=1 ;;
esac
noise_hex="$(off_marker "$(opt noise_hex NOISE_HEX "$(default_noise_hex)")")"
noise_hex_delay="$(opt noise_hex_delay NOISE_HEX_DELAY '1-2')"
noise_rand="$(opt noise_rand NOISE_RAND '23-911')"
noise_count="$(opt noise_count NOISE_COUNT 8)"
noise_delay="$(opt noise_delay NOISE_DELAY '1-3')"
log_level="$(opt log_level LOG_LEVEL warning)"
tun_mode="$(opt tun_mode TUN_MODE 0)"
tun_name="$(opt tun_name TUN_NAME warp0)"
add_direct="$(opt add_direct ADD_DIRECT 0)"

[ -n "$private_key" ] || die "private_key is not set (uci krot_warp.${SECTION}.private_key or WARP_PRIVATE_KEY)"
[ -n "$addresses" ]   || die "addresses is not set (uci krot_warp.${SECTION}.addresses or WARP_ADDRESSES)"
[ -n "$peer_public_key" ] || die "peer_public_key is empty"
[ -n "$endpoint" ]    || die "endpoint is empty"

need_num mtu "$mtu" 576 1500
need_num keepalive "$keepalive" 0 3600
need_num listen_port "$listen_port" 1 65535
need_num noise_count "$noise_count" 0 64
if [ -n "$http_port" ]; then need_num http_port "$http_port" 1 65535; fi

# reserved: ровно три байта 0..255
reserved_oifs="$IFS"; IFS=','
set -- $reserved_csv
IFS="$reserved_oifs"
[ "$#" -eq 3 ] || die "reserved must be exactly three bytes like '0,0,0', got '$reserved_csv'"
r1="$(trim "$1")"; r2="$(trim "$2")"; r3="$(trim "$3")"
need_num "reserved[1]" "$r1" 0 255
need_num "reserved[2]" "$r2" 0 255
need_num "reserved[3]" "$r3" 0 255

addresses_json="$(json_array_from_csv "$addresses")"
[ -n "$addresses_json" ] || die "addresses did not produce any entry: '$addresses'"

if [ "$tun_mode" = "1" ]; then
    case "$tun_name" in
        ''|*[!A-Za-z0-9_.-]*) die "tun_name '$tun_name' is not a valid interface name" ;;
    esac
    if [ "${#tun_name}" -gt 15 ]; then
        die "tun_name '$tun_name' is longer than 15 chars (kernel limit)"
    fi
    warn "tun_mode=1 requires Xray >= 26 (tun inbound); 'xray -test' in the runner decides"
fi

# noises: сначала hex (QUIC-мимикрия), затем N случайных пакетов
noises=''
add_noise() {
    [ -z "$noises" ] || noises="$noises, "
    noises="$noises$1"
}
if [ "$noise_enabled" = "1" ]; then
    if [ -n "$noise_hex" ]; then
        add_noise "{\"type\": \"hex\", \"packet\": \"$(json_escape "$noise_hex")\", \"delay\": \"$(json_escape "$noise_hex_delay")\"}"
    fi
    i=1
    while [ "$i" -le "$noise_count" ]; do
        add_noise "{\"type\": \"rand\", \"packet\": \"$(json_escape "$noise_rand")\", \"delay\": \"$(json_escape "$noise_delay")\"}"
        i=$((i + 1))
    done
fi
[ -n "$noises" ] || warn "noises are off (noise_enabled=0 / noise_hex=off / noise_count=0) — bare WireGuard handshake"


# --- сборка JSON -------------------------------------------------------------
printf '{\n'
printf '  "remarks": "K.R.O.T. WARP %s",\n' "$(json_escape "$SECTION")"
printf '  "log": {\n    "loglevel": "%s"\n  },\n' "$(json_escape "$log_level")"

if [ -n "$dns_servers" ]; then
    printf '  "dns": {\n    "servers": [%s]\n  },\n' "$(json_array_from_csv "$dns_servers")"
fi

printf '  "inbounds": [\n'
printf '    {\n      "tag": "socks-in",\n'
printf '      "listen": "%s",\n' "$(json_escape "$listen_host")"
printf '      "port": %s,\n' "$listen_port"
printf '      "protocol": "socks",\n'
printf '      "settings": {\n        "auth": "noauth",\n        "udp": true\n      },\n'
printf '      "sniffing": {\n        "enabled": true,\n        "destOverride": ["http", "tls"]\n      }\n    }'
if [ -n "$http_port" ]; then
    printf ',\n    {\n      "tag": "http-in",\n'
    printf '      "listen": "%s",\n' "$(json_escape "$listen_host")"
    printf '      "port": %s,\n' "$http_port"
    printf '      "protocol": "http",\n'
    printf '      "settings": {},\n'
    printf '      "sniffing": {\n        "enabled": true,\n        "destOverride": ["http", "tls"]\n      }\n    }'
fi
if [ "$tun_mode" = "1" ]; then
    printf ',\n    {\n      "tag": "tun-in",\n'
    printf '      "protocol": "tun",\n'
    printf '      "settings": {\n        "name": "%s",\n        "MTU": %s\n      }\n    }' \
        "$(json_escape "$tun_name")" "$mtu"
fi
printf '\n  ],\n'

printf '  "outbounds": [\n'
printf '    {\n      "tag": "warp",\n'
printf '      "protocol": "wireguard",\n'
printf '      "settings": {\n'
printf '        "secretKey": "%s",\n' "$(json_escape "$private_key")"
printf '        "address": [%s],\n' "$addresses_json"
printf '        "mtu": %s,\n' "$mtu"
printf '        "noKernelTun": %s,\n' "$(bool_json "$no_kernel_tun")"
printf '        "reserved": [%s, %s, %s],\n' "$r1" "$r2" "$r3"
if [ -n "$remote_dns" ]; then
    printf '        "remoteDNS": [%s],\n' "$(json_array_from_csv "$remote_dns")"
fi
printf '        "peers": [\n          {\n'
printf '            "publicKey": "%s",\n' "$(json_escape "$peer_public_key")"
printf '            "endpoint": "%s",\n' "$(json_escape "$endpoint")"
printf '            "keepAlive": %s,\n' "$keepalive"
printf '            "allowedIPs": ["0.0.0.0/0", "::/0"]\n'
printf '          }\n        ]\n      },\n'
printf '      "streamSettings": {\n        "sockopt": {\n          "dialerProxy": "noise-out"\n        }\n      }\n    },\n'

printf '    {\n      "tag": "noise-out",\n'
printf '      "protocol": "freedom",\n'
printf '      "settings": {\n        "domainStrategy": "AsIs"'
if [ -n "$noises" ]; then
    printf ',\n        "noises": [\n          %s\n        ]' "$noises"
fi
printf '\n      }\n    }'

if [ "$add_direct" = "1" ]; then
    printf ',\n    {\n      "tag": "direct",\n      "protocol": "freedom",\n      "settings": {}\n    }'
fi
printf '\n  ],\n'

printf '  "routing": {\n'
printf '    "domainStrategy": "AsIs",\n'
printf '    "rules": [\n'
printf '      {\n        "type": "field",\n        "network": "tcp,udp",\n        "outboundTag": "warp"\n      }\n'
printf '    ]\n  }\n'
printf '}\n'

