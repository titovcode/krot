#!/bin/sh
# Regression tests for dnsmasq snapshots, direct default routes, and rule signatures.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SOURCE="$ROOT/krot/files/usr/bin/podkop"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/krot-release-regressions.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
FUNCTIONS="$TMP/functions.sh"
: > "$FUNCTIONS"

extract_function() {
    sed -n "/^$1() {/,/^}/p" "$SOURCE" >> "$FUNCTIONS"
    grep -q "^$1() {" "$FUNCTIONS"
}

for function_name in \
    dnsmasq_inherited_default_options \
    dnsmasq_inherited_default_list_options \
    dnsmasq_server_is_domain_forward \
    _dnsmasq_snapshot_load \
    dnsmasq_default_domain_forward_servers \
    get_default_action_outbound_tag \
    sing_box_configure_route \
    sig_tmp_add \
    append_unified_rule_signature
do
    extract_function "$function_name"
done
. "$FUNCTIONS"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_equal() {
    if [ "$1" != "$2" ]; then
        printf 'FAIL: %s\nexpected: <%s>\nactual:   <%s>\n' "$3" "$2" "$1" >&2
        exit 1
    fi
}

assert_file_equal() {
    if ! cmp -s "$1" "$2"; then
        printf 'FAIL: %s\n' "$3" >&2
        diff -u "$2" "$1" >&2 || true
        exit 1
    fi
}

UCI_FIXTURE="$TMP/dhcp.named"
UCI_LOG="$TMP/uci.log"
: > "$UCI_LOG"
uci() {
    printf '%s\n' "$*" >> "$UCI_LOG"
    if [ "$*" = "show dhcp.@dnsmasq[0]" ]; then
        cat "$UCI_FIXTURE"
    elif [ "$*" = "-q show podkop" ]; then
        printf 'podkop.main=section\n'
    fi
}

cat > "$UCI_FIXTURE" <<'EOF'
dhcp.krot=dnsmasq
dhcp.krot.domain='lan'
dhcp.krot.local='/lan/'
dhcp.krot.expandhosts='1'
dhcp.krot.server='8.8.8.8' '1.1.1.1' '/example.com/9.9.9.9'
dhcp.krot.rebind_domain='example.org' 'example.net'
dhcp.krot.unknown='ignored'
EOF

_dnsmasq_snapshot_load
assert_equal "$DNSMASQ_SNAPSHOT_domain" "lan" "named-section scalar domain"
assert_equal "$DNSMASQ_SNAPSHOT_local" "/lan/" "named-section scalar local"
assert_equal "$DNSMASQ_SNAPSHOT_expandhosts" "1" "named-section scalar boolean"
assert_equal "$DNSMASQ_SNAPSHOT_server" "8.8.8.8 1.1.1.1 /example.com/9.9.9.9" "quoted DNS server list"
assert_equal "$DNSMASQ_SNAPSHOT_rebind_domain" "example.org example.net" "quoted inherited list"
assert_equal "$(cat "$UCI_LOG")" "show dhcp.@dnsmasq[0]" "snapshot uses one scoped UCI call"
assert_equal "$(dnsmasq_default_domain_forward_servers)" "/example.com/9.9.9.9" "domain-forward server filtering"
assert_equal "$(wc -l < "$UCI_LOG" | tr -d ' ')" "2" "domain-forward helper reloads one snapshot"
printf 'PASS: named dnsmasq section and quoted lists\n'

cat > "$UCI_FIXTURE" <<'EOF'
dhcp.@dnsmasq[0]=dnsmasq
dhcp.@dnsmasq[0].domainneeded='1'
dhcp.@dnsmasq[0].server='/lan/192.168.1.1' '192.168.1.2'
dhcp.@dnsmasq[0].rebind_domain='router.lan'
EOF
: > "$UCI_LOG"
_dnsmasq_snapshot_load
assert_equal "$DNSMASQ_SNAPSHOT_domainneeded" "1" "anonymous-section scalar option"
assert_equal "$DNSMASQ_SNAPSHOT_domain" "" "unset scalar is reset"
assert_equal "$DNSMASQ_SNAPSHOT_server" "/lan/192.168.1.1 192.168.1.2" "anonymous-section DNS list"
assert_equal "$DNSMASQ_SNAPSHOT_rebind_domain" "router.lan" "single inherited list item"
assert_equal "$(cat "$UCI_LOG")" "show dhcp.@dnsmasq[0]" "anonymous section uses scoped UCI call"
printf 'PASS: anonymous dnsmasq section and inherited values\n'

PODKOP_CONFIG_NAME=podkop
SB_DIRECT_OUTBOUND_TAG=direct
SB_DNS_SERVER_TAG=dns-server
SB_TPROXY_INBOUND_TAG=tproxy-in
SB_DNS_INBOUND_TAG=dns-in
NFT_OUTBOUND_MARK=107
CHECK_PROXY_IP_DOMAIN=proxy.test
FAKEIP_TEST_DOMAIN=fakeip.test
DEFAULT_ACTION=1
config_get() {
    local value
    case "$3" in
    action) value=direct ;;
    default_action) value=${DEFAULT_ACTION:-0} ;;
    *) value=${4:-} ;;
    esac
    eval "$1=\"\$value\""
}
config_get_bool() {
    local value
    if [ "$3" = "default_action" ]; then
        value=${DEFAULT_ACTION:-0}
    else
        value=${4:-0}
    fi
    eval "$1=\"\$value\""
}
rule_is_enabled() { return 0; }
get_rule_action_primitive() { printf 'direct'; }
get_outbound_tag_by_section() {
    if [ "$1" = "main" ]; then printf 'direct'; else printf 'proxy-out'; fi
}
assert_equal "$(get_default_action_outbound_tag)" "direct" "direct default section resolves to direct outbound"
printf 'PASS: direct default-action detection\n'

ROUTE_LOG="$TMP/route.log"
LOG_LOG="$TMP/route-messages.log"
: > "$ROUTE_LOG"
: > "$LOG_LOG"
log() { printf '%s\n' "$1" >> "$LOG_LOG"; }
sing_box_cm_batch_begin() { :; }
sing_box_cm_batch_flush() { SB_CM_BATCH_RESULT=$1; }
sing_box_cm_configure_route() {
    printf '%s\n' "$2" >> "$ROUTE_LOG"
    printf '%s' "$1"
}
sing_box_cm_sniff_route_rule() { printf '%s' "$1"; }
sing_box_cm_add_hijack_dns_route_rule() { printf '%s' "$1"; }
sing_box_cf_add_single_key_reject_rule() { printf '%s' "$1"; }
sing_box_cf_proxy_domain() { printf '%s' "$1"; }
sing_box_cf_override_domain_port() { printf '%s' "$1"; }
comma_string_to_json_array() { printf '[]'; }
config_foreach() { :; }
get_first_outbound_section() { printf 'proxy-section'; }
mwan3_is_active() { return 1; }
module_action_outbounds() { :; }
config='{}'
sing_box_configure_route
assert_equal "$(cat "$ROUTE_LOG")" "direct" "explicit direct remains the final route"
if grep -q 'first proxy section' "$LOG_LOG"; then
    fail "explicit direct incorrectly selected the first proxy fallback"
fi
printf 'PASS: sing-box route preserves explicit direct default\n'

# Use a direct action to keep this fixture independent of unrelated proxy fields.
SIG_TMP_SING_BOX="$TMP/sing-box.sig"
SIG_TMP_NFT="$TMP/nft.sig"
SIG_TMP_ZAPRET_QUEUE="$TMP/zapret-queue.sig"
SIG_TMP_ZAPRET_RUNTIME="$TMP/zapret-runtime.sig"
SIG_TMP_BYEDPI_RUNTIME="$TMP/byedpi.sig"
SIG_TMP_LIST="$TMP/list.sig"
SIG_TMP_CRON="$TMP/cron.sig"
SIG_TMP_CRON_SUB="$TMP/cron-sub.sig"
get_rule_condition_commas_string() { :; }
get_rule_ports_commas_string() { :; }
filter_community_subnet_lists() { :; }
get_rule_module_config_meta() { return 1; }
rule_is_subscription_proxy() { return 1; }

write_expected_signature() {
    cat > "$1" <<EOF
[rule.main.action]
direct
[rule.main.default_action]
$2
[rule.main.domain]

[rule.main.domain_suffix]

[rule.main.domain_keyword]

[rule.main.domain_regex]

[rule.main.ip_cidr]

[rule.main.source_ip_cidr]

[rule.main.ports]

[rule.main.fully_routed_ips]

[rule.main.community_lists]

[rule.main.rule_set]

[rule.main.rule_set_with_subnets]

[rule.main.domain_ip_lists]

EOF
}

DEFAULT_ACTION=0
: > "$SIG_TMP_SING_BOX"
append_unified_rule_signature main
write_expected_signature "$TMP/expected-0.sig" 0
assert_file_equal "$SIG_TMP_SING_BOX" "$TMP/expected-0.sig" "default_action=0 sing-box signature"
DEFAULT_ACTION=1
: > "$SIG_TMP_SING_BOX"
append_unified_rule_signature main
write_expected_signature "$TMP/expected-1.sig" 1
assert_file_equal "$SIG_TMP_SING_BOX" "$TMP/expected-1.sig" "default_action=1 sing-box signature"
if cmp -s "$TMP/expected-0.sig" "$TMP/expected-1.sig"; then
    fail "default_action toggle did not change sing-box signature"
fi
unset DEFAULT_ACTION
: > "$SIG_TMP_SING_BOX"
append_unified_rule_signature main
assert_file_equal "$SIG_TMP_SING_BOX" "$TMP/expected-0.sig" "missing default_action uses zero"
printf 'PASS: default_action toggles sing-box signature (0, 1, and missing)\n'

printf 'All release regression tests passed.\n'
