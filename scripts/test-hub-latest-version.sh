#!/bin/sh
# Test upstream latest-version discovery with manifest fallback.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/krot-hub-latest.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
sed -n '/^hub_get_modules() {/,/^}/p' "$ROOT/krot/files/usr/lib/updater.sh" > "$TMP/function.sh"
. "$TMP/function.sh"

UPDATES_TMP_DIR="$TMP/work"
HUB_CACHE_MAX_AGE=0
HUB_CACHE_FILE="$TMP/cache.json"
PODKOP_RELEASE_REPO=titovcode/krot
UPSTREAM_OK=1
mkdir -p "$UPDATES_TMP_DIR"

updates_init_tmp_dir() { mkdir -p "$UPDATES_TMP_DIR"; }
updates_log() { :; }
json_utils_ucode() { return 0; }
hub_embed_module_templates() { printf '%s' "$4"; }
hub_cache_write() { :; }
uci() { return 1; }
hub_module_installed_status() {
    hub_installed_version=26.11.9
    return 0
}
updates_http_get() {
    case "$1" in
    */index.json*) printf '%s\n' '{"modules":["xray"]}' ;;
    */hub/xray/module.json*) cat "$ROOT/hub/xray/module.json" ;;
    *api.github.com*)
        [ "$UPSTREAM_OK" -eq 1 ] || return 1
        printf '%s\n' '{"tag_name":"v26.11.9"}'
        ;;
    *) return 1 ;;
    esac
}

result="$(hub_get_modules)"
printf '%s' "$result" | grep -q '"latest_version":"26.11.9"' || {
    printf 'FAIL: upstream tag missing: %s\n' "$result" >&2
    exit 1
}
printf 'PASS: upstream release supplies latest_version\n'

UPSTREAM_OK=0
result="$(hub_get_modules)"
printf '%s' "$result" | grep -q '"latest_version":"26.3.27"' || {
    printf 'FAIL: manifest fallback missing: %s\n' "$result" >&2
    exit 1
}
printf 'PASS: manifest version remains the offline fallback\n'
printf 'All Hub latest-version tests passed.\n'
