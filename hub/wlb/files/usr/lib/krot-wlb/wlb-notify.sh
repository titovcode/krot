#!/bin/sh
# wlb-notify.sh <config> <section> <link> — push the new join link to the
# configured targets. Legacy form: wlb-notify.sh <section> <link>
#
# Targets per instance (all optional, all may be combined):
#   (wlb_)notify_telegram_token + (wlb_)notify_telegram_chat — Telegram bot
#   (wlb_)notify_ntfy                                      — ntfy.sh topic URL
#   (wlb_)notify_cmd                                       — custom command ($WLB_LINK)
#
# (wlb_)notify_via_proxy 1 routes Telegram/ntfy through the K.R.O.T. local
# proxy (127.0.0.1:4534) — useful when the target itself is blocked on WAN.
set -u

if [ $# -ge 3 ]; then
    CONFIG_NAME="$1"; SECTION="$2"; LINK="$3"
else
    CONFIG_NAME="krot_wlb"; SECTION="${1:-}"; LINK="${2:-}"
fi
[ -n "$SECTION" ] && [ -n "$LINK" ] || exit 0
[ -f "/etc/config/${CONFIG_NAME}" ] || exit 0

. /lib/functions.sh
# /lib/functions.sh references $IPKG_INSTROOT under `set -u`; define it.
export IPKG_INSTROOT="${IPKG_INSTROOT:-}"
config_load "$CONFIG_NAME"

get_opt() {
    local key="$1" default="$2" value=""
    config_get value "$SECTION" "wlb_${key}" ""
    [ -n "$value" ] || config_get value "$SECTION" "$key" "$default"
    printf '%s' "$value"
}

label="$(get_opt label "$SECTION")"
tg_token="$(get_opt notify_telegram_token "")"
tg_chat="$(get_opt notify_telegram_chat "")"
ntfy_url="$(get_opt notify_ntfy "")"
custom_cmd="$(get_opt notify_cmd "")"
via_proxy="$(get_opt notify_via_proxy 0)"

PROXY_ARG=""
if [ "$via_proxy" = "1" ]; then
    PROXY_ARG="-x http://127.0.0.1:4534"
fi

log() { logger -t "krot-wlb-notify[$SECTION]" -- "$*"; }

# shellcheck disable=SC2086
http_post() {
    # http_post <url> [curl args...]
    local url="$1"; shift
    curl -fsSL --max-time 20 $PROXY_ARG "$@" "$url" >/dev/null 2>&1
}

sent=0

if [ -n "$tg_token" ] && [ -n "$tg_chat" ]; then
    if http_post "https://api.telegram.org/bot${tg_token}/sendMessage" \
        --data-urlencode "chat_id=${tg_chat}" \
        --data-urlencode "text=K.R.O.T. WLB [${label}]: new join link
${LINK}"; then
        sent=1
    else
        log "telegram notify failed"
    fi
fi

if [ -n "$ntfy_url" ]; then
    if http_post "$ntfy_url" \
        -H "Title: K.R.O.T. WLB: ${label}" \
        -H "Tags: mobile_phone" \
        -H "Priority: high" \
        -d "$LINK"; then
        sent=1
    else
        log "ntfy notify failed"
    fi
fi

if [ -n "$custom_cmd" ]; then
    if WLB_LINK="$LINK" WLB_SECTION="$SECTION" WLB_LABEL="$label" sh -c "$custom_cmd" >/dev/null 2>&1; then
        sent=1
    else
        log "custom notify command failed"
    fi
fi

[ "$sent" -eq 1 ] && log "link pushed to configured targets"
exit 0
