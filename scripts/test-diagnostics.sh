#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/krot-diagnostics.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
export work

awk '/^check_dns_available\(\) \{/{copy=1} copy{print} copy && /^\}/{exit}' \
    "$root/krot/files/usr/bin/podkop" > "$work/function.sh"

cat > "$work/test.sh" <<'EOF'
#!/bin/sh
set -eu
scenario=$1
config_get() {
    case "$3" in
        dns_type) value=doh ;;
        dns_server) value=1.1.1.1 ;;
        bootstrap_dns_server) value=1.0.0.1 ;;
        *) return 1 ;;
    esac
    eval "$1=\$value"
}
export work PODKOP_CONFIG_NAME=podkop
config_load() { :; }
check_dhcp_has_podkop_dns() { :; }
is_adguard_installed() { return 1; }
url_get_host() {
    host=${1#*://}
    host=${host%%/*}
    host=${host%%:*}
    printf '%s\n' "$host"
}
url_get_port() { :; }
dig() {
    sleep "${DIG_DELAY:-0.08}"
    case "$scenario" in
        fallback)
            case "$*" in *@1.0.0.1*) return 1 ;; esac
            ;;
        unavailable) return 1 ;;
    esac
    return 0
}
json_utils_ucode() {
    shift
    while [ "$#" -gt 0 ]; do
        printf '%s=%s; ' "$1" "$3"
        shift 3
    done
    printf '\n'
}
. "$work/function.sh"
check_dns_available
EOF

run_case() {
    result=$(sh "$work/test.sh" "$1")
    printf '%s: %s\n' "$1" "$result"
    shift
    for expected in "$@"; do
        printf '%s' "$result" | grep -F "$expected" > /dev/null || {
            printf 'Missing expected result: %s\n' "$expected" >&2
            return 1
        }
    done
}

run_case success 'dns_status=1;' 'dns_on_router=1;' 'bootstrap_dns_status=1;' 'bootstrap_dns_server=1.0.0.1;'
run_case fallback 'dns_status=1;' 'dns_on_router=1;' 'bootstrap_dns_status=1;' 'bootstrap_dns_server=1.0.0.1 (fallback: 8.8.8.8);'
run_case unavailable 'dns_status=0;' 'dns_on_router=0;' 'bootstrap_dns_status=0;' 'bootstrap_dns_server=1.0.0.1;'

DIG_DELAY=0.15 run_case unavailable 'dns_status=0;' 'dns_on_router=0;' 'bootstrap_dns_status=0;'

DIG_DELAY=0.15 start=$(python3 -c 'import time; print(time.time())')
sh "$work/test.sh" unavailable > /dev/null
end=$(python3 -c 'import time; print(time.time())')
python3 - "$start" "$end" <<'EOF'
import sys
elapsed = float(sys.argv[2]) - float(sys.argv[1])
print(f"All DNS timeouts simulated: {elapsed:.3f}s (old schedule: about 1.05s)")
if elapsed >= 0.75:
    raise SystemExit("Parallel DNS checks exceed their timing budget")
EOF

sh -n "$root/krot/files/usr/bin/podkop"
echo "Diagnostics regression tests passed"
