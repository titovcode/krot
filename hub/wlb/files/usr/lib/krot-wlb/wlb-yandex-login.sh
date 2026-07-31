#!/bin/sh
# wlb-yandex-login.sh — QR login to Yandex Passport from the router (no browser).
#
# Flow (same as the Yandex web "Sign in with QR code" button):
#   1. GET  passport.yandex.ru/pwl-yandex                  -> CSRF token
#   2. POST pwl-yandex/api/passport/auth/password/submit   -> track_id
#   3. POST pwl-yandex/api/passport/auth/magic/code        -> QR link
#   4. poll pwl-yandex/api/passport/auth/magic/code/status -> otp_auth_finished
#   5. POST pwl-yandex/api/passport/sessions/get_session   -> session cookies
#   6. dump *.yandex.ru cookies -> /etc/krot-wlb/cookies-yandex.json
#
# Usage: wlb-yandex-login.sh start | status | stop
# State lives in /var/run/krot-wlb/yandex-login/ (status, state, qr.txt files).
set -u

STATE_DIR="/var/run/krot-wlb/yandex-login"
JAR="$STATE_DIR/cookies.jar"
AUTH_JSON="$STATE_DIR/auth.json"
STATUS_FILE="$STATE_DIR/status"
STATE_FILE="$STATE_DIR/state"
QR_FILE="$STATE_DIR/qr.txt"
PID_FILE="$STATE_DIR/pid"
OUT="/etc/krot-wlb/cookies-yandex.json"
BASE="https://passport.yandex.ru"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

log() { logger -t "krot-wlb-yandex" -- "$*"; }
set_status() { echo "$1" > "$STATUS_FILE"; log "$1"; }
die() { set_status "error:$1"; rm -f "$PID_FILE"; exit 1; }

json_val() {
    grep -o "\"$2\":\"[^\"]*\"" "$1" 2>/dev/null | head -1 | cut -d'"' -f4
}

req() {
    curl -fsSL --max-time 20 -A "$UA" -b "$JAR" -c "$JAR" "$@"
}

run() {
    local CSRF TRACK_ID LINK ST FINAL_TRACK i
    rm -f "$JAR"
    set_status "starting"

    # 1. Landing page -> CSRF token
    req "$BASE/pwl-yandex" -o "$STATE_DIR/page.html" || die "cannot reach passport.yandex.ru"
    CSRF="$(grep -o '__CSRF__ = "[^"]*"' "$STATE_DIR/page.html" 2>/dev/null | head -1 | cut -d'"' -f2)"
    [ -n "$CSRF" ] || die "no csrf token on passport page"

    # 2. Create an auth track (passwordless flow, no credentials involved)
    req -X POST -H "X-CSRF-Token: $CSRF" -H "Content-Type: application/json" \
        --data-binary '{"retpath":"https://passport.yandex.ru/"}' \
        "$BASE/pwl-yandex/api/passport/auth/password/submit" -o "$AUTH_JSON" || die "password/submit failed"
    TRACK_ID="$(json_val "$AUTH_JSON" track_id)"
    [ -n "$TRACK_ID" ] || die "no track_id in password/submit response"

    # 3. Request the magic QR code
    req -X POST -H "X-CSRF-Token: $CSRF" \
        --data-urlencode "location_id=0" \
        --data-urlencode "magic_track_id=$TRACK_ID" \
        --data-urlencode "track_id=" \
        "$BASE/pwl-yandex/api/passport/auth/magic/code" -o "$STATE_DIR/magic.json" || die "magic/code failed"
    LINK="$(json_val "$STATE_DIR/magic.json" link)"
    [ -n "$LINK" ] || die "no qr link in magic/code response"
    printf '%s\n' "$LINK" > "$QR_FILE"
    set_status "waiting"

    # 4. Poll until the user confirms in the Yandex app (3 minutes max)
    ST=""
    FINAL_TRACK=""
    i=0
    while [ "$i" -lt 90 ]; do
        i=$((i + 1))
        sleep 2
        req -X POST -H "X-CSRF-Token: $CSRF" -H "Content-Type: application/json" \
            --data-binary "@$AUTH_JSON" \
            "$BASE/pwl-yandex/api/passport/auth/magic/code/status" -o "$STATE_DIR/poll.json" 2>/dev/null || continue
        ST="$(json_val "$STATE_DIR/poll.json" state)"
        [ -n "$ST" ] && echo "$ST" > "$STATE_FILE"
        if [ "$ST" = "otp_auth_finished" ]; then
            FINAL_TRACK="$(json_val "$STATE_DIR/poll.json" trackId)"
            [ -n "$FINAL_TRACK" ] || FINAL_TRACK="$TRACK_ID"
            break
        fi
    done
    [ "$ST" = "otp_auth_finished" ] || die "timeout: QR was not confirmed"

    set_status "authorized"

    # 5. Exchange the track for a real session (Set-Cookie lands in the jar)
    req -X POST -H "X-CSRF-Token: $CSRF" \
        --data-urlencode "track_id=$FINAL_TRACK" \
        "$BASE/pwl-yandex/api/passport/sessions/get_session" -o "$STATE_DIR/session.json" || die "get_session failed"

    # 6. Convert the Netscape cookie jar to whitelist-bypass cookies JSON
    TMPJSON="$STATE_DIR/cookies.json.tmp"
    {
        printf '['
        awk -F'\t' '
            /^#HttpOnly_/ { $0 = substr($0, 11) }
            /^#/ { next }
            NF >= 7 && $1 ~ /yandex\.ru$/ {
                name = $6
                value = $7
                for (j = 8; j <= NF; j++) value = value "\t" $j
                gsub(/\\/, "\\\\", name)
                gsub(/"/, "\\\"", name)
                gsub(/\\/, "\\\\", value)
                gsub(/"/, "\\\"", value)
                printf "%s{\"name\":\"%s\",\"value\":\"%s\"}", (count++ ? "," : ""), name, value
            }
        ' "$JAR"
        printf ']\n'
    } > "$TMPJSON"

    grep -q '"name"' "$TMPJSON" || die "no yandex cookies captured"
    grep -q '"Session_id"' "$TMPJSON" || log "WARNING: Session_id not in captured cookies"

    mkdir -p /etc/krot-wlb
    mv "$TMPJSON" "$OUT"
    chmod 600 "$OUT"

    # Pick up the fresh cookies in all running creators.
    /etc/init.d/krot-wlb reload >/dev/null 2>&1 || true

    set_status "done"
    rm -f "$JAR" "$STATE_DIR/page.html" "$STATE_DIR/magic.json" "$STATE_DIR/poll.json" "$STATE_DIR/session.json"
    rm -f "$PID_FILE"
}

start() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
        exit 0
    fi

    rm -f "$STATUS_FILE" "$STATE_FILE" "$QR_FILE"
    run &
    echo $! > "$PID_FILE"
    exit 0
}

case "${1:-}" in
    start) start ;;
    status) cat "$STATUS_FILE" 2>/dev/null || echo "idle" ;;
    stop)
        if [ -f "$PID_FILE" ]; then
            kill "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
        fi
        rm -rf "$STATE_DIR"
        ;;
    *) echo "usage: $0 start|status|stop" >&2; exit 1 ;;
esac
exit 0
