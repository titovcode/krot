#!/bin/sh
# Regression tests for Hub install/update script selection.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/krot-hub-updates.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
sed -n '/^hub_install_module() {/,/^}/p' "$ROOT/krot/files/usr/lib/updater.sh" > "$TMP/function.sh"
. "$TMP/function.sh"

UPDATES_TMP_DIR="$TMP/work"
mkdir -p "$UPDATES_TMP_DIR"
CALLS="$TMP/calls"
MANIFEST="$TMP/module.json"
MODULE_INSTALLED=1
WITH_UPDATE=1

updates_init_tmp_dir() { mkdir -p "$UPDATES_TMP_DIR"; }
updates_log() { :; }
updates_fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
hub_module_installed_status() { [ "$MODULE_INSTALLED" -eq 1 ]; }
hub_detect_installed_version() { printf '26.11.9\n'; }
hub_refresh_modules_cache() { :; }
refresh_system_info_cache() { :; }
updates_success() { printf 'success:%s\n' "$5" >> "$CALLS"; }
sh() { printf 'run:%s\n' "$1" >> "$CALLS"; }

updates_http_get() {
    case "$1" in
    */module.json)
        if [ "$WITH_UPDATE" -eq 1 ]; then
            printf '%s\n' '{"component":"xray","version":"26.3.27","install_script":"hub/xray/install.sh","update_script":"hub/xray/update.sh"}'
        else
            printf '%s\n' '{"component":"xray","version":"26.3.27","install_script":"hub/xray/install.sh"}'
        fi
        ;;
    *)
        printf 'downloaded:%s\n' "$1" >> "$CALLS"
        printf '# test script\n'
        ;;
    esac
}

run_case() {
    : > "$CALLS"
    hub_install_module xray ""
    if ! grep -q "^downloaded:.*/$1$" "$CALLS"; then
        printf 'FAIL: expected %s\n' "$1" >&2
        cat "$CALLS" >&2
        exit 1
    fi
    if ! grep -q '^success:26.11.9$' "$CALLS"; then
        printf 'FAIL: detected version was not reported\n' >&2
        cat "$CALLS" >&2
        exit 1
    fi
}

run_case hub/xray/update.sh
printf 'PASS: installed module uses its updater\n'

MODULE_INSTALLED=0
run_case hub/xray/install.sh
printf 'PASS: new module uses its installer\n'

MODULE_INSTALLED=1
WITH_UPDATE=0
run_case hub/xray/install.sh
printf 'PASS: module without updater falls back to installer\n'

printf 'All Hub update tests passed.\n'
