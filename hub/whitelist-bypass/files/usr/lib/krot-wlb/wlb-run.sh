#!/bin/sh
# wlb-run.sh <config> <section> — runs one headless whitelist-bypass creator
# under procd.
#
#   wlb-run.sh krot server_phone1      (K.R.O.T. Servers tab, wlb_* options)
#   wlb-run.sh krot_wlb phone1         (legacy module config, plain options)
#
# Responsibilities:
#   - resolve UCI config for the instance
#   - rejoin the last conference when possible (stable link across restarts)
#   - watch the --write-file link file and fire notifications on a new link
set -u

CONFIG_NAME="${1:-krot_wlb}"
SECTION="${2:-}"
[ -n "$SECTION" ] || { echo "usage: $0 <config> <section>" >&2; exit 1; }
[ -f "/etc/config/${CONFIG_NAME}" ] || exit 0

BIN_DIR="/usr/lib/krot-wlb/bin"
RUN_DIR="/var/run/krot-wlb"
PERSIST_DIR="/etc/krot-wlb/state"

. /lib/functions.sh
config_load "$CONFIG_NAME"

# Options are read wlb_-prefixed (krot server sections) with a fallback to the
# plain name (legacy krot_wlb instances).
get_opt() {
    local key="$1" default="$2" value=""
    config_get value "$SECTION" "wlb_${key}" ""
    [ -n "$value" ] || config_get value "$SECTION" "$key" "$default"
    printf '%s' "$value"
}

enabled="$(get_opt enabled 1)"
[ "$enabled" = "0" ] && exit 0

label="$(get_opt label "$SECTION")"
platform="$(get_opt platform telemost)"
resources="$(get_opt resources moderate)"
cookies="$(get_opt cookies "")"
upstream="$(get_opt upstream_socks "")"
rejoin="$(get_opt rejoin 1)"

case "$platform" in
    telemost) BIN="headless-telemost-creator"; JOIN_FLAG="--tm-link"; [ -n "$cookies" ] || cookies="/etc/krot-wlb/cookies-yandex.json" ;;
    vk)       BIN="headless-vk-creator";       JOIN_FLAG="--vk-link"; [ -n "$cookies" ] || cookies="/etc/krot-wlb/cookies-vk.json" ;;
    wbstream) BIN="headless-wbstream-creator"; JOIN_FLAG="--room";    [ -n "$cookies" ] || cookies="/etc/krot-wlb/cookies-wbstream.json" ;;
    dion)     BIN="headless-dion-creator";     JOIN_FLAG="--room";    [ -n "$cookies" ] || cookies="/etc/krot-wlb/cookies-dion.json" ;;
    *) echo "krot-wlb[$SECTION]: unknown platform '$platform'" >&2; exit 1 ;;
esac

LINK_FILE="${RUN_DIR}/${SECTION}.link"   # appended by the creator (--write-file)
SAVED_LINK="${PERSIST_DIR}/${SECTION}.link"
mkdir -p "$RUN_DIR" "$PERSIST_DIR"

log() { logger -t "krot-wlb[$SECTION]" -- "$*"; echo "krot-wlb[$SECTION]: $*"; }

if [ ! -x "${BIN_DIR}/${BIN}" ]; then
    log "binary ${BIN_DIR}/${BIN} is missing; install it via Hub or copy it manually"
    exit 1
fi
if [ ! -s "$cookies" ]; then
    log "WARNING: cookies file '$cookies' is missing or empty; authorization will fail"
fi

# --- Link watcher: persist + notify whenever the active link changes --------
watch_link() {
    local last="" cur=""
    while :; do
        cur="$(awk 'NF{line=$0} END{print line}' "$LINK_FILE" 2>/dev/null)"
        if [ -n "$cur" ] && [ "$cur" != "$last" ]; then
            last="$cur"
            printf '%s\n' "$cur" > "${SAVED_LINK}.tmp" && mv "${SAVED_LINK}.tmp" "$SAVED_LINK"
            log "active link: $cur"
            /usr/lib/krot-wlb/wlb-notify.sh "$CONFIG_NAME" "$SECTION" "$cur" &
        fi
        sleep 2
    done
}
watch_link &
WATCH_PID=$!
trap 'kill "$WATCH_PID" 2>/dev/null' EXIT TERM INT

set -- --cookies "$cookies" --resources "$resources" --write-file "$LINK_FILE"
[ -n "$upstream" ] && set -- "$@" --upstream-socks "$upstream"

SAVED=""
if [ "$rejoin" = "1" ] && [ -s "$SAVED_LINK" ]; then
    SAVED="$(head -n 1 "$SAVED_LINK" 2>/dev/null)"
fi

cd "$BIN_DIR" || exit 1

# Attempt 1: rejoin the saved conference so the QR/link stays the same.
if [ -n "$SAVED" ]; then
    log "rejoining saved conference"
    "./${BIN}" "$@" "$JOIN_FLAG" "$SAVED" &
    CREATOR_PID=$!
    sleep 25
    if kill -0 "$CREATOR_PID" 2>/dev/null; then
        wait "$CREATOR_PID"
        exit $?
    fi
    log "saved conference is gone, creating a new one"
    rm -f "$SAVED_LINK"
fi

# Attempt 2 (or the only one): fresh conference. The watcher picks up the new
# link from $LINK_FILE and pushes it to the configured destinations.
log "starting $BIN (resources=$resources${upstream:+, upstream=$upstream})"
exec "./${BIN}" "$@"
