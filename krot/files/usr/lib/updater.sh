# shellcheck shell=ash

# Hub listing cache. hub_get_modules() performs one HTTPS request per module
# and LuCI rebuilds the module list (with every config template) on each page
# view, so an uncached listing is seconds of "Loading view..." on a router.
# hub_refresh_modules_cache() rewrites it after install/remove.
HUB_CACHE_FILE="/tmp/krot-hub-modules.json"
HUB_CACHE_MAX_AGE=3600

UPDATES_TMP_DIR=""
UPDATES_TARGET_ARCH=""
UPDATES_ARCH_CANDIDATES=""
UPDATES_ZAPRET_ARCH=""
UPDATES_ZAPRET_BUNDLE_URL=""
UPDATES_ZAPRET_BUNDLE_NAME=""
UPDATES_ZAPRET_PACKAGE_FILE=""
UPDATES_ZAPRET_PACKAGE_NAME=""
UPDATES_ZAPRET_PACKAGE_VERSION=""
UPDATES_ZAPRET_RELEASE_URL=""
UPDATES_BYEDPI_ARCH=""
UPDATES_BYEDPI_PACKAGE_URL=""
UPDATES_BYEDPI_PACKAGE_NAME=""
UPDATES_BYEDPI_PACKAGE_FILE=""
UPDATES_BYEDPI_PACKAGE_VERSION=""
UPDATES_BYEDPI_RELEASE_URL=""
UPDATES_PODKOP_BACKEND_URL=""
UPDATES_PODKOP_RELEASE_URL=""
UPDATES_PODKOP_BACKEND_NAME=""
UPDATES_PODKOP_BACKEND_FILE=""
UPDATES_PODKOP_APP_URL=""
UPDATES_PODKOP_APP_NAME=""
UPDATES_PODKOP_APP_FILE=""
UPDATES_PODKOP_I18N_URL=""
UPDATES_PODKOP_I18N_NAME=""
UPDATES_PODKOP_I18N_FILE=""
UPDATES_SING_BOX_EXTENDED_RELEASE_TAG=""
UPDATES_SING_BOX_EXTENDED_RELEASE_URL=""
UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX=""
UPDATES_SING_BOX_EXTENDED_ASSET_URL=""
UPDATES_SING_BOX_EXTENDED_ASSET_NAME=""
UPDATES_JOB_DIR="/var/run/krot/component-actions"
UPDATES_JOB_FINISHED_TTL_MINUTES=60
UPDATES_JOB_ORPHAN_OUTPUT_TTL_MINUTES=60
UPDATES_JOB_STALE_GRACE_SECONDS=15
UPDATES_LOCK_DIR="/var/run/krot/component-action.lock"
UPDATES_LOCK_HELD=0
UPDATES_PODKOP_WAS_RUNNING=0

updates_log() {
    local message="$1"
    local level="${2:-info}"

    log "Updates: $message" "$level"
}

updates_json_file_get_default() {
    local json_file="$1"
    local key="$2"
    local fallback="$3"

    json_utils_ucode json-file-field "$json_file" "$key" "$fallback" 2>/dev/null
}

updates_json_file_running_is() {
    local json_file="$1"
    local expected="$2"

    json_utils_ucode job-running-is "$json_file" "$expected" >/dev/null 2>&1
}

updates_init_tmp_dir() {
    [ -n "$UPDATES_TMP_DIR" ] && return 0

    UPDATES_TMP_DIR="$(mktemp -d /tmp/krot-updates.XXXXXX 2>/dev/null || true)"
    if [ -z "$UPDATES_TMP_DIR" ]; then
        UPDATES_TMP_DIR="/tmp/krot-updates.$$"
        mkdir -p "$UPDATES_TMP_DIR" || return 1
    fi
}

updates_cleanup() {
    [ -n "$UPDATES_TMP_DIR" ] && rm -rf "$UPDATES_TMP_DIR"

    # Clean old HTTP cache entries (older than 1 hour) to prevent /tmp overflow
    if [ -d "$UPDATES_HTTP_CACHE_DIR" ]; then
        find "$UPDATES_HTTP_CACHE_DIR" -type f -mmin +60 -delete 2>/dev/null || true
    fi
}

# Run a command and remove $UPDATES_TMP_DIR afterwards, but only when this
# call is the one that created it.
#
# updates_init_tmp_dir() creates the directory lazily and nothing removes it
# except the trap installed by component_action(). Every other entry point
# that reaches the Hub code (the `krot hub_get_modules` CLI alias used by
# LuCI, the module-config lookup in the daemon start/reload path) leaves a
# /tmp/krot-updates.XXXXXX directory behind per call, which is an unbounded
# leak on tmpfs. Wrapping the call here keeps those paths clean.
#
# The trap in component_action() is deliberately left alone: wrapping it here
# instead would let a Hub read clobber the daemon's own EXIT trap
# (start_failure_cleanup) and release the component-action lock early.
#
# Nesting is safe: an inner call only cleans a directory it created itself, and
# UPDATES_TMP_DIR is reset to "" so a later lazy init starts fresh.
hub_guarded_call() {
    local created_here status

    [ -n "$UPDATES_TMP_DIR" ] || created_here=1

    # Use subshell to catch exit calls from the command
    (
        "$@"
    )
    status=$?

    if [ -n "$created_here" ] && [ -n "$UPDATES_TMP_DIR" ]; then
        rm -rf "$UPDATES_TMP_DIR" 2> /dev/null || true
        UPDATES_TMP_DIR=""
    fi

    return "$status"
}

updates_acquire_component_lock() {
    local owner_pid

    mkdir -p /var/run/krot || return 1

    if mkdir "$UPDATES_LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" >"$UPDATES_LOCK_DIR/pid"
        UPDATES_LOCK_HELD=1
        return 0
    fi

    owner_pid="$(sed -n '1p' "$UPDATES_LOCK_DIR/pid" 2>/dev/null)"
    if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
        return 1
    fi

    # Stale lock: the owner process is gone. Deleting the whole directory and
    # recreating it opens a TOCTOU window, so recover in place instead:
    # 1) drop the stale pid file, 2) hard-link our own into the free slot.
    # ln(2) fails atomically when the slot was taken between (1) and (2), so
    # exactly one waiter wins; the losers back off. The final ownership check
    # makes sure the pid we are releasing later is really ours.
    rm -f "$UPDATES_LOCK_DIR/pid" 2>/dev/null || true
    if printf '%s\n' "$$" >"$UPDATES_LOCK_DIR/pid.new.$$" 2>/dev/null; then
        if ln "$UPDATES_LOCK_DIR/pid.new.$$" "$UPDATES_LOCK_DIR/pid" 2>/dev/null &&
            [ "$(cat "$UPDATES_LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
            rm -f "$UPDATES_LOCK_DIR/pid.new.$$" 2>/dev/null || true
            UPDATES_LOCK_HELD=1
            return 0
        fi
        rm -f "$UPDATES_LOCK_DIR/pid.new.$$" 2>/dev/null || true
        return 1
    fi

    # Another waiter died between its mkdir and its move into the pid slot,
    # leaving a corpse subdirectory that would block every future waiter.
    for pending_dir in "$UPDATES_LOCK_DIR"/pid.*; do
        [ -d "$pending_dir" ] || continue
        pending_owner="$(cat "$pending_dir/pid" 2>/dev/null)"
        [ -n "$pending_owner" ] && kill -0 "$pending_owner" 2>/dev/null && continue
        rm -rf "$pending_dir" 2>/dev/null || true
    done

    # Someone else is trying to acquire the lock right now; let it finish.
    return 1
}

updates_release_component_lock() {
    [ "$UPDATES_LOCK_HELD" -eq 1 ] || return 0

    rm -f "$UPDATES_LOCK_DIR/pid" 2>/dev/null
    rmdir "$UPDATES_LOCK_DIR" 2>/dev/null
    UPDATES_LOCK_HELD=0
}

updates_component_action_cleanup() {
    updates_cleanup
    updates_release_component_lock
}

updates_json_response() {
    local success="$1"
    local component="$2"
    local action="$3"
    local message="$4"
    local current_version="${5:-}"
    local latest_version="${6:-}"
    local changed="${7:-0}"
    local status="${8:-}"
    local release_url="${9:-}"

    json_utils_ucode object-json \
        success b "$success" \
        component s "$component" \
        action s "$action" \
        message s "$message" \
        current_version s "$current_version" \
        latest_version s "$latest_version" \
        changed n "$changed" \
        status s "$status" \
        release_url s "$release_url"
}

updates_success() {
    updates_json_response true "$@"
    exit 0
}

updates_fail() {
    local component="$1"
    local action="$2"
    local message="$3"
    local current_version="${4:-}"
    local latest_version="${5:-}"

    updates_log "$message" "error"
    updates_json_response false "$component" "$action" "$message" "$current_version" "$latest_version" 0
    exit 1
}

updates_job_json_response() {
    local success="$1"
    local job_id="$2"
    local message="${3:-}"

    json_utils_ucode object-json \
        success b "$success" \
        job_id s "$job_id" \
        message s "$message"
}

updates_job_state_path() {
    local job_id="$1"

    case "$job_id" in
    *[!A-Za-z0-9._-]* | "" | "." | "..")
        return 1
        ;;
    esac

    printf '%s/%s.json\n' "$UPDATES_JOB_DIR" "$job_id"
}

updates_job_tmp_file() {
    local target_file="$1"
    local tmp_file

    tmp_file="$(mktemp "${target_file}.XXXXXX" 2>/dev/null || true)"
    if [ -z "$tmp_file" ]; then
        tmp_file="${target_file}.$$.$(date +%s 2>/dev/null).tmp"
        : >"$tmp_file" || return 1
    fi

    printf '%s\n' "$tmp_file"
}

updates_cleanup_component_jobs() {
    local output_file state_file

    [ -d "$UPDATES_JOB_DIR" ] || return 0

    find "$UPDATES_JOB_DIR" -type f -name '*.out' -mmin "+$UPDATES_JOB_ORPHAN_OUTPUT_TTL_MINUTES" 2>/dev/null |
        while IFS= read -r output_file; do
            [ -f "$output_file" ] || continue
            state_file="${output_file%.out}.json"

            if [ -f "$state_file" ]; then
                updates_refresh_running_job_state "$state_file"
                if updates_json_file_running_is "$state_file" true; then
                    continue
                fi
            fi

            rm -f "$output_file" "$state_file" 2>/dev/null || true
        done

    find "$UPDATES_JOB_DIR" -type f -name '*.out.json' -mmin "+$UPDATES_JOB_ORPHAN_OUTPUT_TTL_MINUTES" -delete 2>/dev/null || true

    find "$UPDATES_JOB_DIR" -type f -name '*.json' -mmin "+$UPDATES_JOB_FINISHED_TTL_MINUTES" 2>/dev/null |
        while IFS= read -r state_file; do
            [ -f "$state_file" ] || continue
            if updates_json_file_running_is "$state_file" false; then
                rm -f "$state_file" 2>/dev/null || true
            fi
        done
}

updates_write_running_job_state() {
    local state_file="$1"
    local component="$2"
    local action="$3"
    local pid="${4:-}"
    local tmp_file started_at

    started_at="$(date +%s 2>/dev/null)"
    case "$started_at" in
    "" | *[!0-9]*) started_at=0 ;;
    esac

    mkdir -p "$UPDATES_JOB_DIR" || return 1
    tmp_file="$(updates_job_tmp_file "$state_file")" || return 1

    if [ -n "$pid" ]; then
        json_utils_ucode object-json \
            success b true \
            running b true \
            component s "$component" \
            action s "$action" \
            message s "Component action is running" \
            pid s "$pid" \
            started_at n "$started_at" \
            current_version s "" \
            latest_version s "" \
            changed n 0 \
            status s "" \
            exit_code j null >"$tmp_file" && mv "$tmp_file" "$state_file"
    else
        json_utils_ucode object-json \
            success b true \
            running b true \
            component s "$component" \
            action s "$action" \
            message s "Component action is running" \
            pid j null \
            started_at n "$started_at" \
            current_version s "" \
            latest_version s "" \
            changed n 0 \
            status s "" \
            exit_code j null >"$tmp_file" && mv "$tmp_file" "$state_file"
    fi

    local rc=$?
    rm -f "$tmp_file" 2>/dev/null
    return $rc
}

updates_update_running_job_pid() {
    local state_file="$1"
    local pid="$2"
    local tmp_file

    case "$pid" in
    "" | *[!0-9]*) return 1 ;;
    esac

    tmp_file="$(updates_job_tmp_file "$state_file")" || return 1
    json_utils_ucode updates-set-running-job-pid "$state_file" "$pid" >"$tmp_file" && mv "$tmp_file" "$state_file"

    local rc=$?
    rm -f "$tmp_file" 2>/dev/null
    return $rc
}

updates_mark_stale_job_state() {
    local state_file="$1"
    local tmp_file

    tmp_file="$(updates_job_tmp_file "$state_file")" || return 1
    json_utils_ucode updates-mark-stale-job-state "$state_file" >"$tmp_file" && mv "$tmp_file" "$state_file"

    local rc=$?
    rm -f "$tmp_file" 2>/dev/null
    return $rc
}

updates_started_at_is_within_stale_grace() {
    local started_at="$1"
    local now age

    case "$started_at" in
    "" | *[!0-9]*) return 1 ;;
    esac
    [ "$started_at" -gt 0 ] || return 1

    now="$(date +%s 2>/dev/null)"
    case "$now" in
    "" | *[!0-9]*) return 1 ;;
    esac

    age=$((now - started_at))
    [ "$age" -lt "$UPDATES_JOB_STALE_GRACE_SECONDS" ]
}

updates_refresh_running_job_state() {
    local state_file="$1"
    local pid started_at

    updates_json_file_running_is "$state_file" true || return 0

    pid="$(updates_json_file_get_default "$state_file" pid "")"
    started_at="$(updates_json_file_get_default "$state_file" started_at 0)"
    case "$pid" in
    "" | *[!0-9]*)
        updates_mark_stale_job_state "$state_file"
        return 0
        ;;
    esac

    if kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    updates_started_at_is_within_stale_grace "$started_at" && return 0
    updates_json_file_running_is "$state_file" true || return 0

    updates_mark_stale_job_state "$state_file"
}

updates_write_finished_job_state() {
    local state_file="$1"
    local component="$2"
    local action="$3"
    local exit_code="$4"
    local output_file="$5"
    local tmp_file json_file raw_output updated_at

    tmp_file="$(updates_job_tmp_file "$state_file")" || return 1
    json_file="$output_file.json"
    updated_at="$(date +%s 2>/dev/null)"
    case "$updated_at" in
    "" | *[!0-9]*) updated_at=0 ;;
    esac

    if json_utils_ucode file-json-valid "$output_file" >/dev/null 2>&1; then
        json_utils_ucode updates-finish-job-state "$output_file" "$exit_code" "$updated_at" >"$tmp_file" && mv "$tmp_file" "$state_file"
        rm -f "$tmp_file" "$output_file"
        return 0
    fi

    sed -n 's/^[^{]*\({.*\)$/\1/p' "$output_file" 2>/dev/null | tail -n 1 >"$json_file"
    if [ -s "$json_file" ] && json_utils_ucode file-json-valid "$json_file" >/dev/null 2>&1; then
        json_utils_ucode updates-finish-job-state "$json_file" "$exit_code" "$updated_at" >"$tmp_file" && mv "$tmp_file" "$state_file"
        rm -f "$tmp_file" "$json_file" "$output_file"
        return 0
    fi
    rm -f "$json_file"

    raw_output="$(tr '\n' ' ' <"$output_file" 2>/dev/null | cut -c1-240)"
    [ -n "$raw_output" ] || raw_output="Failed to execute"

    json_utils_ucode updates-fallback-job-state "$component" "$action" "$raw_output" "$exit_code" "$updated_at" >"$tmp_file" && mv "$tmp_file" "$state_file"

    rm -f "$tmp_file" "$output_file"
}

component_action_async() {
    local component="$1"
    local action="$2"
    local action_arg="$3"
    local job_id state_file output_file job_pid

    mkdir -p "$UPDATES_JOB_DIR" || {
        updates_job_json_response false "" "Failed to create component action state directory"
        exit 1
    }

    updates_cleanup_component_jobs
    job_id="$(date +%s 2>/dev/null)-$$"
    state_file="$(updates_job_state_path "$job_id")" || {
        updates_job_json_response false "" "Failed to prepare component action job"
        exit 1
    }
    output_file="$UPDATES_JOB_DIR/$job_id.out"

    updates_write_running_job_state "$state_file" "$component" "$action" || {
        updates_job_json_response false "" "Failed to write component action state"
        exit 1
    }

    (
        trap '' HUP
        /usr/bin/krot component_action "$component" "$action" "$action_arg" >"$output_file" 2>&1
        updates_write_finished_job_state "$state_file" "$component" "$action" "$?" "$output_file"
    ) >/dev/null 2>&1 &
    job_pid="$!"

    updates_update_running_job_pid "$state_file" "$job_pid" || {
        kill "$job_pid" 2>/dev/null || true
        updates_job_json_response false "" "Failed to write component action worker pid"
        exit 1
    }

    updates_job_json_response true "$job_id" "Component action started"
}

component_action_status() {
    local job_id="$1"
    local state_file

    mkdir -p "$UPDATES_JOB_DIR" 2>/dev/null || true
    updates_cleanup_component_jobs

    state_file="$(updates_job_state_path "$job_id")" || {
        updates_json_response false "unknown" "status" "Invalid component action job id" "" "" 0 ""
        exit 1
    }

    if [ ! -f "$state_file" ]; then
        updates_json_response false "unknown" "status" "Component action job was not found" "" "" 0 ""
        exit 1
    fi

    updates_refresh_running_job_state "$state_file"

    cat "$state_file"
}

updates_command_exists() {
    command -v "$1" >/dev/null 2>&1
}

updates_is_apk() {
    updates_command_exists apk
}

updates_read_openwrt_release_value() {
    local key="$1"

    [ -f /etc/openwrt_release ] || return 0
    sed -n "s/^${key}='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null | head -n 1
}

updates_get_service_proxy_address() {
    local service_proxy_address

    if ! command -v get_service_proxy_address >/dev/null 2>&1; then
        return 0
    fi

    if command -v sing_box_service_is_running >/dev/null 2>&1 && ! sing_box_service_is_running; then
        return 0
    fi

    service_proxy_address="$(get_service_proxy_address 2>/dev/null || true)"
    printf '%s' "$service_proxy_address"
}

# HTTP cache settings for update checks (prevents LuCI from hanging on slow networks)
UPDATES_HTTP_CACHE_DIR="/tmp/krot-http-cache"
UPDATES_HTTP_CACHE_MAX_AGE=600  # 10 minutes
UPDATES_HTTP_TIMEOUT=3          # 3 seconds max per request

updates_http_get_cache_path() {
    local url="$1"
    # Create safe filename from URL (md5sum or fallback to sanitized string)
    if command -v md5sum >/dev/null 2>&1; then
        echo "$UPDATES_HTTP_CACHE_DIR/$(echo "$url" | md5sum | cut -d' ' -f1)"
    else
        # Fallback: replace non-alphanumeric with underscore
        local safe_name="$(echo "$url" | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-100)"
        echo "$UPDATES_HTTP_CACHE_DIR/$safe_name"
    fi
}

updates_http_get_once() {
    local url="$1"
    local output_path="$2"
    local service_proxy_address="${3:-}"

    if updates_command_exists curl; then
        if [ -n "$service_proxy_address" ]; then
            curl --connect-timeout 2 -m "$UPDATES_HTTP_TIMEOUT" -fsSL -x "http://$service_proxy_address" "$url" -o "$output_path"
        else
            curl --connect-timeout 2 -m "$UPDATES_HTTP_TIMEOUT" -fsSL "$url" -o "$output_path"
        fi
        return $?
    fi

    if updates_command_exists wget; then
        if [ -n "$service_proxy_address" ]; then
            http_proxy="http://$service_proxy_address" https_proxy="http://$service_proxy_address" \
                wget -T "$UPDATES_HTTP_TIMEOUT" -q -O "$output_path" "$url"
        else
            wget -T "$UPDATES_HTTP_TIMEOUT" -q -O "$output_path" "$url"
        fi
        return $?
    fi

    return 1
}

updates_http_get() {
    local url="$1"
    local service_proxy_address output_path cache_path cache_age now mtime

    # Ensure cache directory exists with restricted permissions
    if [ ! -d "$UPDATES_HTTP_CACHE_DIR" ]; then
        mkdir -p "$UPDATES_HTTP_CACHE_DIR" 2>/dev/null || true
        chmod 700 "$UPDATES_HTTP_CACHE_DIR" 2>/dev/null || true
    fi

    cache_path="$(updates_http_get_cache_path "$url")"

    # Check if we have fresh cached data
    if [ -f "$cache_path" ]; then
        now="$(date +%s)"
        mtime="$(stat -c %Y "$cache_path" 2>/dev/null || echo 0)"
        cache_age=$((now - mtime))

        if [ "$cache_age" -lt "$UPDATES_HTTP_CACHE_MAX_AGE" ]; then
            cat "$cache_path"
            return 0
        fi
    fi

    # Cache miss or stale - try to fetch fresh data
    output_path="$(mktemp /tmp/krot-updates-http.XXXXXX 2>/dev/null || true)"
    [ -n "$output_path" ] || {
        # If mktemp failed but we have stale cache, use it
        [ -f "$cache_path" ] && cat "$cache_path"
        return 1
    }

    service_proxy_address="$(updates_get_service_proxy_address)"
    if [ -n "$service_proxy_address" ]; then
        if updates_http_get_once "$url" "$output_path" "$service_proxy_address"; then
            # Save to cache with restricted permissions and output
            cp "$output_path" "$cache_path" 2>/dev/null && chmod 600 "$cache_path" 2>/dev/null || true
            cat "$output_path"
            rm -f "$output_path"
            return 0
        fi

        rm -f "$output_path"
        updates_log "HTTP request via service proxy failed for $url; retrying directly" "warn"
    fi

    if updates_http_get_once "$url" "$output_path" ""; then
        # Save to cache with restricted permissions and output
        cp "$output_path" "$cache_path" 2>/dev/null && chmod 600 "$cache_path" 2>/dev/null || true
        cat "$output_path"
        rm -f "$output_path"
        return 0
    fi

    rm -f "$output_path"

    # Network failed - return stale cache if available
    if [ -f "$cache_path" ]; then
        updates_log "Using stale cache for $url (network unavailable)" "debug"
        cat "$cache_path"
        return 0
    fi

    return 1
}

updates_download_file_once_with_proxy() {
    local url="$1"
    local output_path="$2"
    local service_proxy_address="${3:-}"

    if updates_command_exists curl; then
        if [ -n "$service_proxy_address" ]; then
            curl --connect-timeout 3 -m 120 -fsSL -x "http://$service_proxy_address" "$url" -o "$output_path"
        else
            curl --connect-timeout 3 -m 120 -fsSL "$url" -o "$output_path"
        fi
        return $?
    fi

    if updates_command_exists wget; then
        if [ -n "$service_proxy_address" ]; then
            http_proxy="http://$service_proxy_address" https_proxy="http://$service_proxy_address" \
                wget -T 120 --connect-timeout=3 -q -O "$output_path" "$url"
        else
            wget -T 120 --connect-timeout=3 -q -O "$output_path" "$url"
        fi
        return $?
    fi

    return 1
}

updates_download_file_once() {
    local url="$1"
    local output_path="$2"
    local service_proxy_address

    service_proxy_address="$(updates_get_service_proxy_address)"
    if [ -n "$service_proxy_address" ]; then
        if updates_download_file_once_with_proxy "$url" "$output_path" "$service_proxy_address"; then
            return 0
        fi

        rm -f "$output_path"
        updates_log "Download via service proxy failed for $url; retrying directly" "warn"
    fi

    updates_download_file_once_with_proxy "$url" "$output_path" ""
}

updates_download_with_retry() {
    local url="$1"
    local output_path="$2"
    local label="$3"
    local attempt=1
    local max_attempts=3

    while [ "$attempt" -le "$max_attempts" ]; do
        updates_log "Downloading $label ($attempt/$max_attempts)"

        if updates_download_file_once "$url" "$output_path" && [ -s "$output_path" ]; then
            return 0
        fi

        rm -f "$output_path"
        updates_log "Retrying $label" "warn"
        attempt=$((attempt + 1))
    done

    return 1
}

updates_log_command() {
    local description="$1"
    local status output_file line level
    shift

    output_file="$(mktemp /tmp/krot-updates-command.XXXXXX 2>/dev/null || true)"
    [ -n "$output_file" ] || output_file="/tmp/krot-updates-command.$$"

    updates_log "$description"
    "$@" >"$output_file" 2>&1
    status=$?

    level="info"
    [ "$status" -eq 0 ] || level="error"

    while IFS= read -r line; do
        [ -n "$line" ] && updates_log "$line" "$level"
    done <"$output_file"

    rm -f "$output_file"
    return "$status"
}

updates_pkg_is_installed() {
    local package_name="$1"

    if updates_is_apk; then
        apk info -e "$package_name" >/dev/null 2>&1
        return $?
    fi

    opkg list-installed 2>/dev/null | grep -Eq "^${package_name}([[:space:]-]|$)"
}

updates_get_installed_package_version() {
    local package_name="$1"

    if updates_is_apk; then
        apk info -e "$package_name" >/dev/null 2>&1 || return 0
        get_apk_installed_package_version "$package_name"
        return 0
    fi

    opkg list-installed 2>/dev/null | awk -v pkg="$package_name" '$1 == pkg && $2 == "-" {print $3; exit}'
}

updates_get_available_package_version() {
    local package_name="$1"

    if updates_is_apk; then
        apk policy "$package_name" 2>/dev/null |
            awk '
                /^  [^[:space:]][^[:space:]]*:/ {
                    version=$1
                    sub(/:$/, "", version)
                    print version
                    exit
                }
            '
        return 0
    fi

    opkg list "$package_name" 2>/dev/null |
        awk -v pkg="$package_name" '$1 == pkg && $2 == "-" {print $3; exit}'
}

updates_pkg_list_update() {
    if updates_is_apk; then
        apk update </dev/null
    else
        opkg update </dev/null
    fi
}

updates_pkg_install_name() {
    local package_name="$1"

    if updates_is_apk; then
        apk add "$package_name" </dev/null
    else
        opkg install "$package_name" </dev/null
    fi
}

updates_pkg_install_name_downgrade() {
    local package_name="$1"

    if updates_is_apk; then
        apk add "$package_name" </dev/null
    else
        opkg install --force-reinstall --force-downgrade "$package_name" </dev/null ||
            opkg install --force-downgrade "$package_name" </dev/null
    fi
}

updates_pkg_install_files() {
    if updates_is_apk; then
        apk add --allow-untrusted "$@" </dev/null
    else
        opkg install --force-overwrite --force-downgrade "$@" </dev/null
    fi
}

updates_pkg_remove_name() {
    local package_name="$1"

    if ! updates_pkg_is_installed "$package_name"; then
        return 0
    fi

    if updates_is_apk; then
        apk del "$package_name" </dev/null
    else
        opkg remove --force-depends "$package_name" </dev/null
    fi
}

updates_compare_versions() {
    local lhs="$1"
    local rhs="$2"
    local newest

    [ -n "$lhs" ] || return 1
    [ -n "$rhs" ] || return 1

    [ "$lhs" = "$rhs" ] && echo 0 && return 0

    if updates_is_apk; then
        case "$(apk version -t "$lhs" "$rhs" 2>/dev/null || true)" in
        ">") echo 1 && return 0 ;;
        "<") echo -1 && return 0 ;;
        "=") echo 0 && return 0 ;;
        esac
    fi

    if updates_command_exists opkg; then
        if opkg compare-versions "$lhs" ">" "$rhs" >/dev/null 2>&1; then
            echo 1
            return 0
        fi
        if opkg compare-versions "$lhs" "<" "$rhs" >/dev/null 2>&1; then
            echo -1
            return 0
        fi
        if opkg compare-versions "$lhs" "=" "$rhs" >/dev/null 2>&1; then
            echo 0
            return 0
        fi
    fi

    newest="$(printf '%s\n%s\n' "$rhs" "$lhs" | sort -V | tail -n 1)"
    if [ "$newest" = "$lhs" ]; then
        echo 1
    else
        echo -1
    fi
}

updates_status_from_compare() {
    local compare_result="$1"

    case "$compare_result" in
    -1) printf '%s\n' "outdated" ;;
    0) printf '%s\n' "latest" ;;
    1) printf '%s\n' "dev" ;;
    *) return 1 ;;
    esac
}

updates_check_success() {
    local component="$1"
    local current_version="$2"
    local latest_version="$3"
    local release_url="${4:-}"

    updates_check_success_compared "$component" "$current_version" "$latest_version" "$current_version" "$latest_version" "$release_url"
}

updates_check_success_compared() {
    local component="$1"
    local current_version="$2"
    local latest_version="$3"
    local compare_current_version="$4"
    local compare_latest_version="$5"
    local release_url="${6:-}"
    local compare_result status message

    compare_result="$(updates_compare_versions "$compare_current_version" "$compare_latest_version" 2>/dev/null || true)"
    [ -n "$compare_result" ] || updates_fail "$component" "check_update" "Failed to compare versions" "$current_version" "$latest_version"

    status="$(updates_status_from_compare "$compare_result")" || updates_fail "$component" "check_update" "Failed to compare versions" "$current_version" "$latest_version"

    case "$status" in
    latest)
        message="Latest version is installed"
        updates_log "$component is up to date ($current_version)" "debug"
        ;;
    outdated)
        message="Update is available"
        updates_log "$component update is available: $current_version -> $latest_version"
        ;;
    dev)
        message="Installed version is newer than release"
        updates_log "$component installed version is newer than upstream release: $current_version -> $latest_version" "debug"
        ;;
    esac

    updates_success "$component" "check_update" "$message" "$current_version" "$latest_version" 0 "$status" "$release_url"
}

updates_fetch_podkop_latest_release_metadata() {
    local release_json tag release_url

    local raw_url latest_json tag release_url

    raw_url="https://raw.githubusercontent.com/${PODKOP_RELEASE_REPO}/main/latest.json?v=$(date +%s)"
    latest_json="$(updates_http_get "$raw_url" 2>/dev/null)" || return 1
    [ -n "$latest_json" ] || return 1

    tag="$(printf '%s' "$latest_json" | json_utils_ucode object-get-default version "" 2>/dev/null)"
    [ -n "$tag" ] || return 1
    release_url="$(printf '%s' "$latest_json" | json_utils_ucode object-get-default url "" 2>/dev/null)"
    [ -n "$release_url" ] || release_url="https://github.com/${PODKOP_RELEASE_REPO}/releases/tag/${tag}"

    printf '%s\t%s\n' "$tag" "$release_url"
}

updates_ensure_package_tool() {
    local tool_name="$1"
    local package_name="$2"

    if updates_command_exists "$tool_name"; then
        return 0
    fi

    updates_log_command "Updating package lists before installing $package_name" updates_pkg_list_update || return 1
    updates_log_command "Installing bootstrap package $package_name" updates_pkg_install_name "$package_name"
}

updates_retry_resolve() {
    local description="$1"
    local command_name="$2"
    local attempt=1
    local max_attempts=3

    while [ "$attempt" -le "$max_attempts" ]; do
        if "$command_name"; then
            return 0
        fi

        updates_log "$description failed ($attempt/$max_attempts)" "warn"
        attempt=$((attempt + 1))
        sleep 2
    done

    return 1
}

updates_clear_version_caches() {
    rm -f /tmp/krot.latest-version.cache
    rm -f "$PODKOP_SYSTEM_INFO_CACHE_FILE"
    rm -f /tmp/krot/system-info.json
}

updates_capture_podkop_running_state() {
    UPDATES_PODKOP_WAS_RUNNING=0

    [ -x "$PODKOP_SERVICE_INIT" ] || return 0

    if "$PODKOP_SERVICE_INIT" status >/dev/null 2>&1; then
        UPDATES_PODKOP_WAS_RUNNING=1
    fi
}

updates_restart_podkop_after_successful_change() {
    [ -x "$PODKOP_SERVICE_INIT" ] || return 0

    if [ "$UPDATES_PODKOP_WAS_RUNNING" != "1" ]; then
        updates_log "K.R.O.T. was not running before component change; restart skipped"
        return 0
    fi

    updates_log_command "Restarting K.R.O.T. after successful component change" "$PODKOP_SERVICE_INIT" restart || true
}

updates_append_arch_candidate() {
    local candidate="$1"

    [ -n "$candidate" ] || return 0

    case "$candidate" in
    all | noarch)
        return 0
        ;;
    esac

    case " $UPDATES_ARCH_CANDIDATES " in
    *" $candidate "*)
        return 0
        ;;
    esac

    if [ -n "$UPDATES_ARCH_CANDIDATES" ]; then
        UPDATES_ARCH_CANDIDATES="$UPDATES_ARCH_CANDIDATES $candidate"
    else
        UPDATES_ARCH_CANDIDATES="$candidate"
    fi
}

updates_append_arch_candidate_variants() {
    local candidate="$1"
    local base_candidate suffix

    [ -n "$candidate" ] || return 0

    updates_append_arch_candidate "$candidate"

    case "$candidate" in
    *+*)
        updates_append_arch_candidate "${candidate%%+*}"
        ;;
    esac

    for suffix in _musl _uclibc _glibc -musl -uclibc -glibc .musl .uclibc .glibc; do
        case "$candidate" in
        *"$suffix")
            base_candidate="${candidate%"$suffix"}"
            updates_append_arch_candidate "$base_candidate"
            ;;
        esac
    done
}

updates_add_arch_family_fallbacks() {
    local arch="$1"

    updates_append_arch_candidate_variants "$arch"

    case "$arch" in
    aarch64_*)
        updates_append_arch_candidate_variants "aarch64_generic"
        ;;
    riscv64_*)
        updates_append_arch_candidate_variants "riscv64_generic"
        ;;
    arm_cortex-a7_neon-vfpv4)
        updates_append_arch_candidate_variants "arm_cortex-a7_vfpv4"
        updates_append_arch_candidate_variants "arm_cortex-a7"
        ;;
    arm_cortex-a7_*)
        updates_append_arch_candidate_variants "arm_cortex-a7"
        ;;
    arm_cortex-a9_*)
        updates_append_arch_candidate_variants "arm_cortex-a9"
        ;;
    mipsel_24kc_24kf)
        updates_append_arch_candidate_variants "mipsel_24kc"
        ;;
    esac
}

updates_resolve_arch_candidates() {
    local arch_list apk_arch_list release_arch arch

    UPDATES_TARGET_ARCH=""
    UPDATES_ARCH_CANDIDATES=""

    if updates_is_apk; then
        if [ -f /etc/apk/arch ]; then
            apk_arch_list="$(tr '\r\n' '  ' </etc/apk/arch)"
            [ -n "$apk_arch_list" ] && arch_list="$arch_list $apk_arch_list"
        fi

        apk_arch_list="$(apk --print-arch 2>/dev/null || true)"
        [ -n "$apk_arch_list" ] && arch_list="$arch_list $apk_arch_list"
    else
        arch_list="$(opkg print-architecture 2>/dev/null | awk '$1 == "arch" && $2 !~ /^(all|noarch)$/ {print $2 " " $3}' | sort -k2,2nr | awk '{print $1}')"
    fi

    release_arch="$(updates_read_openwrt_release_value "DISTRIB_ARCH")"
    [ -n "$release_arch" ] && arch_list="$arch_list $release_arch"

    if [ -z "$(printf '%s' "$arch_list" | tr -d '[:space:]')" ]; then
        arch_list="$(uname -m 2>/dev/null || true)"
    fi

    for arch in $arch_list; do
        case "$arch" in
        all | noarch)
            continue
            ;;
        esac

        [ -n "$UPDATES_TARGET_ARCH" ] || UPDATES_TARGET_ARCH="$arch"
        updates_add_arch_family_fallbacks "$arch"
    done

    [ -n "$UPDATES_TARGET_ARCH" ] || return 1
    updates_log "Detected package architecture candidates: $UPDATES_ARCH_CANDIDATES"
}

updates_fetch_github_release_json() {
    local owner="$1"
    local repo="$2"
    local response

    response="$(updates_http_get "https://api.github.com/repos/${owner}/${repo}/releases/latest" 2>/dev/null || true)"
    [ -n "$response" ] || return 1
    printf '%s' "$response" | json_utils_ucode github-response-ok >/dev/null 2>&1 || return 1

    printf '%s' "$response"
}

updates_fetch_github_releases_json() {
    local owner="$1"
    local repo="$2"
    local per_page="${3:-30}"
    local response

    response="$(updates_http_get "https://api.github.com/repos/${owner}/${repo}/releases?per_page=${per_page}" 2>/dev/null || true)"
    [ -n "$response" ] || return 1
    printf '%s' "$response" | json_utils_ucode github-response-ok >/dev/null 2>&1 || return 1

    printf '%s' "$response"
}

updates_extract_arch_package_version() {
    local package_name="$1"
    local package_arch="$2"
    local version

    version="$(printf '%s\n' "$package_name" | sed 's/\.ipk$//;s/\.apk$//')"

    case "$version" in
    zapret_*) version="${version#zapret_}" ;;
    zapret-*) version="${version#zapret-}" ;;
    byedpi_*) version="${version#byedpi_}" ;;
    byedpi-*) version="${version#byedpi-}" ;;
    esac

    if [ -n "$package_arch" ]; then
        case "$version" in
        *_$package_arch) version="${version%_$package_arch}" ;;
        *-$package_arch) version="${version%-$package_arch}" ;;
        esac
    fi

    printf '%s\n' "$version"
}

updates_select_release_asset_name() {
    local release_json="$1"
    local package_prefix="$2"
    local asset_ext="$3"

    printf '%s' "$release_json" | json_utils_ucode release-asset-name "$package_prefix" "$asset_ext"
}

updates_select_release_asset_url() {
    local release_json="$1"
    local asset_name="$2"

    printf '%s' "$release_json" | json_utils_ucode release-asset-url "$asset_name" | sed -n '1p'
}

updates_resolve_krot_release() {
    local latest_version="$1"
    local owner repo asset_ext release_json release_tag

    UPDATES_PODKOP_BACKEND_URL=""
    UPDATES_PODKOP_RELEASE_URL=""
    UPDATES_PODKOP_BACKEND_NAME=""
    UPDATES_PODKOP_APP_URL=""
    UPDATES_PODKOP_APP_NAME=""
    UPDATES_PODKOP_I18N_URL=""
    UPDATES_PODKOP_I18N_NAME=""

    owner="${PODKOP_RELEASE_REPO%%/*}"
    repo="${PODKOP_RELEASE_REPO#*/}"
    [ -n "$owner" ] || return 1
    [ -n "$repo" ] || return 1
    [ "$owner" != "$repo" ] || return 1

    asset_ext="ipk"
    updates_is_apk && asset_ext="apk"

    release_json="$(updates_fetch_github_release_json "$owner" "$repo")" || return 1
    [ -n "$release_json" ] || return 1
    release_tag="$(printf '%s' "$release_json" | json_utils_ucode object-get-default tag_name "" 2>/dev/null)"
    [ "$release_tag" = "$latest_version" ] || return 1
    UPDATES_PODKOP_RELEASE_URL="$(printf '%s' "$release_json" | json_utils_ucode object-get-default html_url "" 2>/dev/null)"

    UPDATES_PODKOP_BACKEND_NAME="$(updates_select_release_asset_name "$release_json" "krot" "$asset_ext")"
    UPDATES_PODKOP_APP_NAME="$(updates_select_release_asset_name "$release_json" "luci-app-krot" "$asset_ext")"
    [ -n "$UPDATES_PODKOP_BACKEND_NAME" ] || return 1
    [ -n "$UPDATES_PODKOP_APP_NAME" ] || return 1

    UPDATES_PODKOP_BACKEND_URL="$(updates_select_release_asset_url "$release_json" "$UPDATES_PODKOP_BACKEND_NAME")"
    UPDATES_PODKOP_APP_URL="$(updates_select_release_asset_url "$release_json" "$UPDATES_PODKOP_APP_NAME")"
    [ -n "$UPDATES_PODKOP_BACKEND_URL" ] || return 1
    [ -n "$UPDATES_PODKOP_APP_URL" ] || return 1

    if updates_pkg_is_installed "luci-i18n-krot-ru"; then
        UPDATES_PODKOP_I18N_NAME="$(updates_select_release_asset_name "$release_json" "luci-i18n-krot-ru" "$asset_ext")"
        [ -n "$UPDATES_PODKOP_I18N_NAME" ] || return 1
        UPDATES_PODKOP_I18N_URL="$(updates_select_release_asset_url "$release_json" "$UPDATES_PODKOP_I18N_NAME")"
        [ -n "$UPDATES_PODKOP_I18N_URL" ] || return 1
    fi
}

updates_download_krot_packages() {
    UPDATES_PODKOP_BACKEND_FILE="$UPDATES_TMP_DIR/$UPDATES_PODKOP_BACKEND_NAME"
    UPDATES_PODKOP_APP_FILE="$UPDATES_TMP_DIR/$UPDATES_PODKOP_APP_NAME"
    UPDATES_PODKOP_I18N_FILE=""

    updates_download_with_retry "$UPDATES_PODKOP_BACKEND_URL" "$UPDATES_PODKOP_BACKEND_FILE" "$UPDATES_PODKOP_BACKEND_NAME" || return 1
    updates_download_with_retry "$UPDATES_PODKOP_APP_URL" "$UPDATES_PODKOP_APP_FILE" "$UPDATES_PODKOP_APP_NAME" || return 1

    if [ -n "$UPDATES_PODKOP_I18N_URL" ]; then
        UPDATES_PODKOP_I18N_FILE="$UPDATES_TMP_DIR/$UPDATES_PODKOP_I18N_NAME"
        updates_download_with_retry "$UPDATES_PODKOP_I18N_URL" "$UPDATES_PODKOP_I18N_FILE" "$UPDATES_PODKOP_I18N_NAME" || return 1
    fi
}

updates_refresh_luci_after_app_update() {
    rm -f /var/luci-indexcache* /tmp/luci-indexcache* 2>/dev/null || true
    rm -rf /tmp/luci-modulecache/ 2>/dev/null || true
    [ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1 && return 0
    [ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1 && return 0
    killall -HUP rpcd 2>/dev/null || true
}

updates_get_openwrt_release_series() {
    local release

    release="$(updates_read_openwrt_release_value "DISTRIB_RELEASE")"
    printf '%s\n' "$release" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'
}

updates_resolve_zapret_release() {
    local release_json candidate_name arch url

    UPDATES_ZAPRET_ARCH=""
    UPDATES_ZAPRET_BUNDLE_URL=""
    UPDATES_ZAPRET_BUNDLE_NAME=""
    UPDATES_ZAPRET_PACKAGE_VERSION=""
    UPDATES_ZAPRET_RELEASE_URL=""

    release_json="$(updates_fetch_github_release_json "remittor" "zapret-openwrt")" || return 1
    UPDATES_ZAPRET_RELEASE_URL="$(printf '%s' "$release_json" | json_utils_ucode object-get-default html_url "" 2>/dev/null)"

    for arch in $UPDATES_ARCH_CANDIDATES; do
        candidate_name="$(printf '%s' "$release_json" | json_utils_ucode release-asset-name-by-suffix "_${arch}.zip" 2>/dev/null)"
        if [ -n "$candidate_name" ]; then
            UPDATES_ZAPRET_ARCH="$arch"
            UPDATES_ZAPRET_BUNDLE_NAME="$candidate_name"
            break
        fi
    done

    [ -n "$UPDATES_ZAPRET_BUNDLE_NAME" ] || return 1

    url="$(printf '%s' "$release_json" | json_utils_ucode release-asset-url "$UPDATES_ZAPRET_BUNDLE_NAME" 2>/dev/null)"
    [ -n "$url" ] || return 1
    UPDATES_ZAPRET_BUNDLE_URL="$url"
    UPDATES_ZAPRET_PACKAGE_VERSION="$(updates_extract_zapret_bundle_version "$UPDATES_ZAPRET_BUNDLE_NAME")"
    [ -n "$UPDATES_ZAPRET_PACKAGE_VERSION" ] || UPDATES_ZAPRET_PACKAGE_VERSION="$(printf '%s\n' "$UPDATES_ZAPRET_BUNDLE_NAME" | sed 's/\.zip$//')"
}

updates_download_and_extract_zapret_package() {
    local bundle_file inner_package_path

    UPDATES_ZAPRET_PACKAGE_FILE=""
    UPDATES_ZAPRET_PACKAGE_NAME=""
    UPDATES_ZAPRET_PACKAGE_VERSION=""

    bundle_file="$UPDATES_TMP_DIR/$UPDATES_ZAPRET_BUNDLE_NAME"
    updates_download_with_retry "$UPDATES_ZAPRET_BUNDLE_URL" "$bundle_file" "$UPDATES_ZAPRET_BUNDLE_NAME" || return 1

    if updates_is_apk; then
        inner_package_path="$(unzip -l "$bundle_file" | awk '{print $4}' | grep -E '^apk/zapret-.*\.apk$' | sed -n '1p')"
    else
        inner_package_path="$(unzip -l "$bundle_file" | awk '{print $4}' | grep -E "^zapret_.*_${UPDATES_ZAPRET_ARCH}\.ipk$" | sed -n '1p')"
        [ -n "$inner_package_path" ] || inner_package_path="$(unzip -l "$bundle_file" | awk '{print $4}' | grep -E '^zapret_.*\.ipk$' | sed -n '1p')"
    fi

    [ -n "$inner_package_path" ] || return 1

    UPDATES_ZAPRET_PACKAGE_NAME="$(basename "$inner_package_path")"
    UPDATES_ZAPRET_PACKAGE_FILE="$UPDATES_TMP_DIR/$UPDATES_ZAPRET_PACKAGE_NAME"

    unzip -p "$bundle_file" "$inner_package_path" >"$UPDATES_ZAPRET_PACKAGE_FILE" || return 1
    [ -s "$UPDATES_ZAPRET_PACKAGE_FILE" ] || return 1

    [ -n "$UPDATES_ZAPRET_PACKAGE_VERSION" ] || UPDATES_ZAPRET_PACKAGE_VERSION="$(updates_extract_zapret_bundle_version "$UPDATES_ZAPRET_BUNDLE_NAME")"
    [ -n "$UPDATES_ZAPRET_PACKAGE_VERSION" ] || UPDATES_ZAPRET_PACKAGE_VERSION="$(updates_extract_arch_package_version "$UPDATES_ZAPRET_PACKAGE_NAME" "$UPDATES_ZAPRET_ARCH")"
}

updates_resolve_byedpi_release() {
    local response release_series asset_ext resolved

    UPDATES_BYEDPI_ARCH=""
    UPDATES_BYEDPI_PACKAGE_URL=""
    UPDATES_BYEDPI_PACKAGE_NAME=""
    UPDATES_BYEDPI_PACKAGE_VERSION=""
    UPDATES_BYEDPI_RELEASE_URL=""

    asset_ext="ipk"
    updates_is_apk && asset_ext="apk"
    release_series="$(updates_get_openwrt_release_series)"

    response="$(updates_fetch_github_releases_json "DPITrickster" "ByeDPI-OpenWrt" 30)" || return 1

    resolved="$(printf '%s' "$response" | json_utils_ucode byedpi-select-asset "$release_series" "$asset_ext" "$UPDATES_ARCH_CANDIDATES" 2>/dev/null)"

    [ -n "$resolved" ] || return 1

    UPDATES_BYEDPI_ARCH="$(printf '%s\n' "$resolved" | cut -f1)"
    UPDATES_BYEDPI_PACKAGE_NAME="$(printf '%s\n' "$resolved" | cut -f2)"
    UPDATES_BYEDPI_PACKAGE_URL="$(printf '%s\n' "$resolved" | cut -f3)"
    UPDATES_BYEDPI_RELEASE_URL="$(printf '%s\n' "$resolved" | cut -f4)"

    [ -n "$UPDATES_BYEDPI_ARCH" ] || return 1
    [ -n "$UPDATES_BYEDPI_PACKAGE_NAME" ] || return 1
    [ -n "$UPDATES_BYEDPI_PACKAGE_URL" ] || return 1

    UPDATES_BYEDPI_PACKAGE_VERSION="$(updates_extract_arch_package_version "$UPDATES_BYEDPI_PACKAGE_NAME" "$UPDATES_BYEDPI_ARCH")"
}

updates_download_byedpi_package() {
    UPDATES_BYEDPI_PACKAGE_FILE="$UPDATES_TMP_DIR/$UPDATES_BYEDPI_PACKAGE_NAME"
    updates_download_with_retry "$UPDATES_BYEDPI_PACKAGE_URL" "$UPDATES_BYEDPI_PACKAGE_FILE" "$UPDATES_BYEDPI_PACKAGE_NAME" || return 1
    [ -s "$UPDATES_BYEDPI_PACKAGE_FILE" ] || return 1

    [ -n "$UPDATES_BYEDPI_PACKAGE_VERSION" ] || UPDATES_BYEDPI_PACKAGE_VERSION="$(updates_extract_arch_package_version "$UPDATES_BYEDPI_PACKAGE_NAME" "$UPDATES_BYEDPI_ARCH")"
}

updates_disable_standalone_zapret_service() {
    [ -x /etc/init.d/zapret ] || return 0

    updates_log_command "Stopping standalone zapret service" /etc/init.d/zapret stop || true
    updates_log_command "Disabling standalone zapret autostart" /etc/init.d/zapret disable || true
}

updates_disable_standalone_byedpi_service() {
    [ -x /etc/init.d/byedpi ] || return 0

    updates_log_command "Stopping standalone byedpi service" /etc/init.d/byedpi stop || true
    updates_log_command "Disabling standalone byedpi autostart" /etc/init.d/byedpi disable || true
}

updates_install_zapret() {
    local action="$1"
    local current_version installed normalized_current normalized_latest

    updates_init_tmp_dir || updates_fail "zapret" "$action" "Failed to create temporary directory"
    updates_resolve_arch_candidates || updates_fail "zapret" "$action" "Failed to detect package architecture"
    updates_retry_resolve "Resolving zapret package" updates_resolve_zapret_release ||
        updates_fail "zapret" "$action" "Failed to resolve zapret package for this router architecture"

    installed=0
    is_zapret_installed && installed=1
    current_version="$(get_zapret_package_version)"

    if [ "$action" = "check_update" ]; then
        [ "$installed" -eq 1 ] || updates_fail "zapret" "$action" "zapret is not installed" "$current_version" "$UPDATES_ZAPRET_PACKAGE_VERSION"
        normalized_current="$(updates_normalize_zapret_version "$current_version")"
        normalized_latest="$(updates_normalize_zapret_version "$UPDATES_ZAPRET_PACKAGE_VERSION")"
        updates_check_success_compared "zapret" "$current_version" "$UPDATES_ZAPRET_PACKAGE_VERSION" "$normalized_current" "$normalized_latest" "$UPDATES_ZAPRET_RELEASE_URL"
    fi

    updates_ensure_package_tool "unzip" "unzip" || updates_fail "zapret" "$action" "Failed to install unzip"
    updates_download_and_extract_zapret_package || updates_fail "zapret" "$action" "Failed to download zapret package"

    if ! updates_log_command "Installing zapret package $UPDATES_ZAPRET_PACKAGE_NAME" updates_pkg_install_files "$UPDATES_ZAPRET_PACKAGE_FILE"; then
        updates_fail "zapret" "$action" "Failed to install zapret package" "$current_version" "$UPDATES_ZAPRET_PACKAGE_VERSION"
    fi

    updates_disable_standalone_zapret_service
    updates_restart_podkop_after_successful_change
    updates_clear_version_caches

    current_version="$(get_zapret_package_version)"
    updates_success "zapret" "$action" "zapret package has been installed" "$current_version" "$UPDATES_ZAPRET_PACKAGE_VERSION" 1 "latest"
}

updates_install_byedpi() {
    local action="$1"
    local current_version installed

    updates_init_tmp_dir || updates_fail "byedpi" "$action" "Failed to create temporary directory"
    updates_resolve_arch_candidates || updates_fail "byedpi" "$action" "Failed to detect package architecture"
    updates_retry_resolve "Resolving ByeDPI package" updates_resolve_byedpi_release ||
        updates_fail "byedpi" "$action" "Failed to resolve ByeDPI package for this router architecture"

    installed=0
    is_byedpi_installed && installed=1
    current_version="$(get_byedpi_package_version)"

    if [ "$action" = "check_update" ]; then
        [ "$installed" -eq 1 ] || updates_fail "byedpi" "$action" "ByeDPI is not installed" "$current_version" "$UPDATES_BYEDPI_PACKAGE_VERSION"
        updates_check_success "byedpi" "$current_version" "$UPDATES_BYEDPI_PACKAGE_VERSION" "$UPDATES_BYEDPI_RELEASE_URL"
    fi

    updates_download_byedpi_package || updates_fail "byedpi" "$action" "Failed to download ByeDPI package"

    if ! updates_log_command "Installing ByeDPI package $UPDATES_BYEDPI_PACKAGE_NAME" updates_pkg_install_files "$UPDATES_BYEDPI_PACKAGE_FILE"; then
        updates_fail "byedpi" "$action" "Failed to install ByeDPI package" "$current_version" "$UPDATES_BYEDPI_PACKAGE_VERSION"
    fi

    updates_disable_standalone_byedpi_service
    updates_restart_podkop_after_successful_change
    updates_clear_version_caches

    current_version="$(get_byedpi_package_version)"
    updates_success "byedpi" "$action" "ByeDPI package has been installed" "$current_version" "$UPDATES_BYEDPI_PACKAGE_VERSION" 1 "latest"
}

updates_remove_optional_component() {
    local component="$1"
    local action="remove"
    local package_name="$2"
    local label="$3"
    local provider_check="$4"
    local version_getter="$5"
    local current_version

    if ! updates_pkg_is_installed "$package_name"; then
        if "$provider_check"; then
            updates_fail "$component" "$action" "$label exists outside the package manager and was not removed automatically"
        fi

        updates_success "$component" "$action" "$label is already removed" "" "" 0
    fi

    current_version="$("$version_getter")"

    if ! updates_log_command "Removing $label package" updates_pkg_remove_name "$package_name"; then
        updates_fail "$component" "$action" "Failed to remove $label package" "$current_version"
    fi

    updates_clear_version_caches

    if "$provider_check"; then
        updates_fail "$component" "$action" "$label package was removed, but provider files are still present" "$current_version"
    fi

    updates_restart_podkop_after_successful_change

    updates_success "$component" "$action" "$label package has been removed" "$current_version" "" 1
}

updates_normalize_sing_box_version() {
    printf '%s\n' "$1" |
        sed 's/^v//;s/+.*$//;s/[[:space:]].*$//'
}

updates_system_uses_musl() {
    ls /lib/ld-musl-*.so* >/dev/null 2>&1 && return 0

    ldd --version 2>&1 | grep -qi 'musl'
}

updates_select_sing_box_extended_asset_url() {
    local release_json="$1"
    local asset_pattern asset_url

    if updates_system_uses_musl; then
        asset_pattern="linux-${UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX}-musl.tar.gz"
        asset_url="$(printf '%s' "$release_json" | json_utils_ucode release-asset-url-by-suffix "$asset_pattern" 2>/dev/null)"
        if [ -n "$asset_url" ]; then
            printf '%s\n' "$asset_url"
            return 0
        fi
    fi

    asset_pattern="linux-${UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX}.tar.gz"
    asset_url="$(printf '%s' "$release_json" | json_utils_ucode release-asset-url-by-suffix "$asset_pattern" 2>/dev/null)"
    if [ -n "$asset_url" ]; then
        printf '%s\n' "$asset_url"
        return 0
    fi

    return 1
}

updates_read_sing_box_binary_version() {
    local binary="$1"
    local library_dir="${2:-}"

    [ -n "$binary" ] || return 1
    [ -x "$binary" ] || return 1

    if [ -n "$library_dir" ]; then
        LD_LIBRARY_PATH="$library_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$binary" version 2>/dev/null | head -n 1 | awk '{print $NF}'
        return $?
    fi

    "$binary" version 2>/dev/null | head -n 1 | awk '{print $NF}'
}

updates_validate_sing_box_extended_binary() {
    local binary="$1"
    local library_dir="${2:-}"
    local version

    version="$(updates_read_sing_box_binary_version "$binary" "$library_dir")"
    case "$version" in
    *extended*)
        printf '%s\n' "$version"
        return 0
        ;;
    esac

    return 1
}

updates_restore_sing_box_backup() {
    local backup_binary="$1"

    if [ -n "$backup_binary" ] && [ -s "$backup_binary" ]; then
        mv -f "$backup_binary" /usr/bin/sing-box && chmod 0755 /usr/bin/sing-box
        return $?
    fi

    rm -f /usr/bin/sing-box
}

updates_restore_file_backup() {
    local target_path="$1"
    local backup_path="$2"

    if [ -n "$backup_path" ] && [ -s "$backup_path" ]; then
        mv -f "$backup_path" "$target_path"
        return $?
    fi

    rm -f "$target_path"
}

updates_extract_zapret_bundle_version() {
    local bundle_name="$1"
    local version

    version="$(basename "$bundle_name" | sed -n 's/^zapret_v\([^_][^_]*\)_.*/\1/p')"
    [ -n "$version" ] || version="$(basename "$bundle_name" | sed -n 's/^zapret_\([^_][^_]*\)_.*/\1/p')"

    printf '%s\n' "$version" | sed 's/^v//'
}

updates_normalize_zapret_version() {
    printf '%s\n' "$1" |
        sed 's/^v//;s/-r[0-9][0-9]*$//;s/+.*$//;s/[[:space:]].*$//'
}

updates_resolve_sing_box_extended_arch_suffix() {
    local host_arch distrib_arch

    host_arch="$(uname -m 2>/dev/null || true)"
    distrib_arch="$(updates_read_openwrt_release_value "DISTRIB_ARCH")"

    case "$distrib_arch" in
    *mipsel* | *mipsle*) host_arch="mipsel" ;;
    *mips64el* | *mips64le*) host_arch="mips64el" ;;
    esac

    case "$host_arch" in
    aarch64) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="arm64" ;;
    armv7*) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="armv7" ;;
    armv6*) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="armv6" ;;
    x86_64) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="amd64" ;;
    i386 | i686) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="386" ;;
    mips) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="mips-softfloat" ;;
    mipsel | mipsle) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="mipsle-softfloat" ;;
    mips64) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="mips64" ;;
    mips64el | mips64le) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="mips64le" ;;
    riscv64) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="riscv64" ;;
    s390x) UPDATES_SING_BOX_EXTENDED_ARCH_SUFFIX="s390x" ;;
    *) return 1 ;;
    esac
}

updates_resolve_sing_box_extended_release() {
    local response tag release_json

    UPDATES_SING_BOX_EXTENDED_RELEASE_TAG=""
    UPDATES_SING_BOX_EXTENDED_RELEASE_URL=""
    UPDATES_SING_BOX_EXTENDED_ASSET_URL=""
    UPDATES_SING_BOX_EXTENDED_ASSET_NAME=""

    updates_resolve_sing_box_extended_arch_suffix || return 1
    response="$(updates_fetch_github_releases_json "shtorm-7" "sing-box-extended" 30)" || return 1

    tag="$(printf '%s' "$response" | json_utils_ucode sing-box-extended-release-tag 2>/dev/null)"

    [ -n "$tag" ] || return 1
    UPDATES_SING_BOX_EXTENDED_RELEASE_TAG="$tag"
    release_json="$(printf '%s' "$response" | json_utils_ucode release-by-tag "$tag" 2>/dev/null)"
    UPDATES_SING_BOX_EXTENDED_RELEASE_URL="$(printf '%s' "$release_json" | json_utils_ucode object-get-default html_url "" 2>/dev/null)"
    UPDATES_SING_BOX_EXTENDED_ASSET_URL="$(updates_select_sing_box_extended_asset_url "$release_json")"

    [ -n "$UPDATES_SING_BOX_EXTENDED_ASSET_URL" ] || return 1
    UPDATES_SING_BOX_EXTENDED_ASSET_NAME="$(basename "$UPDATES_SING_BOX_EXTENDED_ASSET_URL")"
}

updates_install_sing_box_extended() {
    local action="$1"
    local current_version latest_version normalized_current normalized_latest archive_file binary_path cronet_path target_binary target_cronet extract_error new_version backup_binary backup_cronet

    updates_init_tmp_dir || updates_fail "sing_box" "$action" "Failed to create temporary directory"
    current_version="$(get_sing_box_version)"
    updates_resolve_sing_box_extended_release || updates_fail "sing_box" "$action" "Failed to resolve sing-box-extended release" "$current_version"
    latest_version="$(updates_normalize_sing_box_version "$UPDATES_SING_BOX_EXTENDED_RELEASE_TAG")"
    normalized_current="$(updates_normalize_sing_box_version "$current_version")"
    normalized_latest="$(updates_normalize_sing_box_version "$latest_version")"

    if [ "$action" = "check_update" ]; then
        is_sing_box_extended "$current_version" || updates_fail "sing_box" "$action" "sing-box-extended is not installed" "$current_version" "$latest_version"
        updates_check_success "sing_box" "$normalized_current" "$normalized_latest" "$UPDATES_SING_BOX_EXTENDED_RELEASE_URL"
    fi

    archive_file="$UPDATES_TMP_DIR/$UPDATES_SING_BOX_EXTENDED_ASSET_NAME"
    updates_download_with_retry "$UPDATES_SING_BOX_EXTENDED_ASSET_URL" "$archive_file" "$UPDATES_SING_BOX_EXTENDED_ASSET_NAME" ||
        updates_fail "sing_box" "$action" "Failed to download sing-box-extended" "$current_version" "$latest_version"

    binary_path="$(tar -tzf "$archive_file" 2>/dev/null | grep -E '(^|/)sing-box$' | sed -n '1p')"
    [ -n "$binary_path" ] || updates_fail "sing_box" "$action" "sing-box binary was not found in the downloaded archive" "$current_version" "$latest_version"
    cronet_path="$(tar -tzf "$archive_file" 2>/dev/null | grep -E '(^|/)libcronet\.so$' | sed -n '1p')"

    target_binary="/usr/bin/.sing-box.new.$$"
    target_cronet=""
    extract_error="$UPDATES_TMP_DIR/sing-box-extract.err"

    if ! tar -xzf "$archive_file" -O "$binary_path" >"$target_binary" 2>"$extract_error"; then
        while IFS= read -r line; do
            [ -n "$line" ] && updates_log "$line" "error"
        done <"$extract_error"
        rm -f "$target_binary"
        updates_fail "sing_box" "$action" "Failed to extract sing-box-extended" "$current_version" "$latest_version"
    fi

    if [ ! -s "$target_binary" ]; then
        rm -f "$target_binary"
        updates_fail "sing_box" "$action" "sing-box binary was empty after extraction" "$current_version" "$latest_version"
    fi

    if ! chmod 0755 "$target_binary"; then
        rm -f "$target_binary"
        updates_fail "sing_box" "$action" "Failed to prepare sing-box-extended binary" "$current_version" "$latest_version"
    fi

    if [ -n "$cronet_path" ]; then
        target_cronet="$UPDATES_TMP_DIR/libcronet.so"
        if ! tar -xzf "$archive_file" -O "$cronet_path" >"$target_cronet" 2>"$extract_error"; then
            while IFS= read -r line; do
                [ -n "$line" ] && updates_log "$line" "error"
            done <"$extract_error"
            rm -f "$target_binary" "$target_cronet"
            updates_fail "sing_box" "$action" "Failed to extract libcronet.so from sing-box-extended archive" "$current_version" "$latest_version"
        fi

        if [ ! -s "$target_cronet" ]; then
            rm -f "$target_binary" "$target_cronet"
            updates_fail "sing_box" "$action" "libcronet.so was empty after extraction" "$current_version" "$latest_version"
        fi

        if ! chmod 0644 "$target_cronet"; then
            rm -f "$target_binary" "$target_cronet"
            updates_fail "sing_box" "$action" "Failed to prepare libcronet.so" "$current_version" "$latest_version"
        fi
    fi

    new_version="$(updates_validate_sing_box_extended_binary "$target_binary" "$UPDATES_TMP_DIR")" || {
        rm -f "$target_binary" "$target_cronet"
        updates_fail "sing_box" "$action" "Downloaded sing-box-extended binary failed validation" "$current_version" "$latest_version"
    }

    backup_binary=""
    if [ -e /usr/bin/sing-box ]; then
        backup_binary="$UPDATES_TMP_DIR/sing-box.backup.$$"
        if ! cp -p /usr/bin/sing-box "$backup_binary"; then
            rm -f "$target_binary" "$target_cronet" "$backup_binary"
            updates_fail "sing_box" "$action" "Failed to backup current sing-box binary" "$current_version" "$latest_version"
        fi
    fi

    backup_cronet=""
    if [ -n "$target_cronet" ] && [ -e /usr/lib/libcronet.so ]; then
        backup_cronet="$UPDATES_TMP_DIR/libcronet.so.backup.$$"
        if ! cp -p /usr/lib/libcronet.so "$backup_cronet"; then
            rm -f "$target_binary" "$target_cronet" "$backup_binary" "$backup_cronet"
            updates_fail "sing_box" "$action" "Failed to backup current libcronet.so" "$current_version" "$latest_version"
        fi
    fi

    if ! mv -f "$target_binary" /usr/bin/sing-box; then
        rm -f "$target_binary" "$target_cronet"
        updates_restore_sing_box_backup "$backup_binary" >/dev/null 2>&1 || true
        updates_restore_file_backup /usr/lib/libcronet.so "$backup_cronet" >/dev/null 2>&1 || true
        updates_fail "sing_box" "$action" "Failed to install sing-box-extended" "$current_version" "$latest_version"
    fi

    if [ -n "$target_cronet" ] && ! mv -f "$target_cronet" /usr/lib/libcronet.so; then
        updates_restore_sing_box_backup "$backup_binary" >/dev/null 2>&1 || true
        updates_restore_file_backup /usr/lib/libcronet.so "$backup_cronet" >/dev/null 2>&1 || true
        updates_fail "sing_box" "$action" "Failed to install libcronet.so" "$current_version" "$latest_version"
    fi

    new_version="$(updates_validate_sing_box_extended_binary /usr/bin/sing-box /usr/lib)" || {
        updates_restore_file_backup /usr/lib/libcronet.so "$backup_cronet" >/dev/null 2>&1 || true
        if updates_restore_sing_box_backup "$backup_binary"; then
            updates_fail "sing_box" "$action" "Installed sing-box-extended failed validation; previous binary was restored" "$current_version" "$latest_version"
        fi
        updates_fail "sing_box" "$action" "Installed sing-box-extended failed validation and previous binary could not be restored" "$current_version" "$latest_version"
    }

    rm -f "$backup_binary" "$backup_cronet"
    updates_restart_podkop_after_successful_change
    updates_clear_version_caches
    updates_log "Installed sing-box-extended ${new_version:-unknown}"
    updates_success "sing_box" "$action" "sing-box-extended has been installed" "$new_version" "$latest_version" 1 "latest"
}

updates_install_stable_sing_box() {
    local action="$1"
    local current_version latest_version new_version changed

    current_version="$(updates_get_installed_package_version "sing-box")"
    [ -n "$current_version" ] || current_version="$(get_sing_box_version)"
    latest_version="$(updates_get_available_package_version "sing-box")"
    [ -n "$latest_version" ] || latest_version="$(updates_get_installed_package_version "sing-box")"
    [ -n "$latest_version" ] || updates_fail "sing_box" "$action" "Failed to resolve stable sing-box package version" "$current_version"

    if [ "$action" = "check_update" ]; then
        updates_check_success "sing_box" "$current_version" "$latest_version"
    fi

    updates_log_command "Updating package lists before sing-box installation" updates_pkg_list_update ||
        updates_fail "sing_box" "$action" "Failed to update package lists" "$current_version" "$latest_version"

    latest_version="$(updates_get_available_package_version "sing-box")"
    [ -n "$latest_version" ] || latest_version="$(updates_get_installed_package_version "sing-box")"
    [ -n "$latest_version" ] || updates_fail "sing_box" "$action" "Failed to resolve stable sing-box package version" "$current_version"

    if ! updates_log_command "Installing stable sing-box package" updates_pkg_install_name_downgrade "sing-box"; then
        updates_fail "sing_box" "$action" "Failed to install stable sing-box" "$current_version" "$latest_version"
    fi

    updates_restart_podkop_after_successful_change
    updates_clear_version_caches

    new_version="$(get_sing_box_version)"
    changed=1
    [ "$new_version" = "$current_version" ] && changed=0

    updates_success "sing_box" "$action" "stable sing-box has been installed" "$new_version" "$latest_version" "$changed" "latest"
}

updates_check_krot() {
    local release_metadata latest_version release_url compare_result status message now

    release_metadata="$(updates_fetch_podkop_latest_release_metadata 2>/dev/null || true)"
    latest_version="$(printf '%s\n' "$release_metadata" | cut -f1)"
    release_url="$(printf '%s\n' "$release_metadata" | cut -f2)"
    [ -n "$latest_version" ] || latest_version="unknown"

    if [ "$latest_version" = "unknown" ]; then
        updates_log "Failed to check K.R.O.T. updates" "warn"
        updates_json_response false "podkop" "check_update" "Failed to check K.R.O.T. updates" "$PODKOP_VERSION" "$latest_version" 0
        exit 1
    fi

    now="$(date +%s 2>/dev/null)"
    case "$now" in
    '' | *[!0-9]*) now=0 ;;
    esac

    # Only cache a well-formed release version. A malformed latest.json entry
    # (e.g. "dev") would otherwise poison LuCI with a bogus "update available"
    # banner for the whole cache lifetime.
    is_podkop_release_version "$latest_version" &&
        write_podkop_latest_version_cache "$latest_version" "$now"

    if ! is_podkop_release_version "$PODKOP_VERSION"; then
        updates_log "K.R.O.T. current version is not a release version ($PODKOP_VERSION)"
        updates_success "podkop" "check_update" "Installed version is newer than release" "$PODKOP_VERSION" "$latest_version" 0 "dev" "$release_url"
    fi

    compare_result="$(podkop_release_version_compare "$PODKOP_VERSION" "$latest_version" 2>/dev/null || true)"
    if [ -z "$compare_result" ]; then
        updates_fail "podkop" "check_update" "Failed to compare K.R.O.T. versions" "$PODKOP_VERSION" "$latest_version"
    fi

    status="$(updates_status_from_compare "$compare_result")" || updates_fail "podkop" "check_update" "Failed to compare K.R.O.T. versions" "$PODKOP_VERSION" "$latest_version"
    case "$status" in
    latest)
        message="Latest version is installed"
        updates_log "K.R.O.T. is already up to date ($PODKOP_VERSION)" "debug"
        ;;
    outdated)
        message="Update is available"
        updates_log "K.R.O.T. update found: $PODKOP_VERSION -> $latest_version"
        ;;
    dev)
        message="Installed version is newer than release"
        updates_log "K.R.O.T. installed version is newer than upstream release: $PODKOP_VERSION -> $latest_version" "debug"
        ;;
    esac

    updates_success "podkop" "check_update" "$message" "$PODKOP_VERSION" "$latest_version" 0 "$status" "$release_url"
}

updates_install_krot() {
    local latest_version now new_version

    latest_version="$(fetch_latest_podkop_version)"
    [ -n "$latest_version" ] || latest_version="unknown"

    if [ "$latest_version" = "unknown" ]; then
        updates_fail "podkop" "install" "Failed to resolve K.R.O.T. release" "$PODKOP_VERSION" "$latest_version"
    fi

    now="$(date +%s 2>/dev/null)"
    case "$now" in
    '' | *[!0-9]*) now=0 ;;
    esac
    write_podkop_latest_version_cache "$latest_version" "$now"

    updates_init_tmp_dir || updates_fail "podkop" "install" "Failed to create temporary directory" "$PODKOP_VERSION" "$latest_version"
    updates_log "Resolving K.R.O.T. release $latest_version packages"
    updates_resolve_krot_release "$latest_version" ||
        updates_fail "podkop" "install" "Failed to resolve K.R.O.T. release packages" "$PODKOP_VERSION" "$latest_version"
    updates_download_krot_packages ||
        updates_fail "podkop" "install" "Failed to download K.R.O.T. release packages" "$PODKOP_VERSION" "$latest_version"

    if ! updates_log_command "Installing LuCI app package $UPDATES_PODKOP_APP_NAME" updates_pkg_install_files "$UPDATES_PODKOP_APP_FILE"; then
        updates_fail "podkop" "install" "Failed to install LuCI app package" "$PODKOP_VERSION" "$latest_version"
    fi

    if [ -n "$UPDATES_PODKOP_I18N_FILE" ]; then
        if ! updates_log_command "Installing LuCI Russian i18n package $UPDATES_PODKOP_I18N_NAME" updates_pkg_install_files "$UPDATES_PODKOP_I18N_FILE"; then
            updates_fail "podkop" "install" "Failed to install LuCI Russian i18n package" "$PODKOP_VERSION" "$latest_version"
        fi
    fi

    if ! updates_log_command "Installing K.R.O.T. package $UPDATES_PODKOP_BACKEND_NAME" updates_pkg_install_files "$UPDATES_PODKOP_BACKEND_FILE"; then
        updates_fail "podkop" "install" "Failed to install K.R.O.T. package" "$PODKOP_VERSION" "$latest_version"
    fi

    updates_refresh_luci_after_app_update
    # The krot package postinst already starts the service when enabled
    # sections exist, so no extra restart is needed after package install.
    updates_clear_version_caches

    new_version="$(updates_get_installed_package_version "krot")"
    [ -n "$new_version" ] || new_version="$latest_version"
    updates_log "K.R.O.T. updated to $new_version"
    updates_success "podkop" "install" "K.R.O.T. has been installed" "$new_version" "$latest_version" 1 "latest" "$UPDATES_PODKOP_RELEASE_URL"
}

component_action() {
    local component="$1"
    local action="$2"
    local action_arg="$3"

    trap updates_component_action_cleanup EXIT HUP
    trap 'updates_component_action_cleanup; exit 130' INT TERM

    updates_acquire_component_lock || updates_fail "${component:-unknown}" "${action:-unknown}" "Another component action is already running"
    updates_capture_podkop_running_state

    case "$component:$action" in
    podkop:check_update)
        updates_check_krot
        ;;
    podkop:install)
        updates_install_krot
        ;;
    sing_box:check_update)
        if is_sing_box_extended "$(get_sing_box_version)"; then
            updates_install_sing_box_extended "$action"
        fi
        updates_install_stable_sing_box "$action"
        ;;
    sing_box:install)
        if is_sing_box_extended "$(get_sing_box_version)"; then
            updates_install_sing_box_extended "$action"
        fi
        updates_install_stable_sing_box "$action"
        ;;
    sing_box:install_extended)
        updates_install_sing_box_extended "$action"
        ;;
    sing_box:install_stable)
        updates_install_stable_sing_box "$action"
        ;;
    hub:add_source)
        hub_add_source "$action_arg"
        ;;
    hub:remove_source)
        hub_remove_source "$action_arg"
        ;;
    hub:list_sources)
        hub_list_sources
        ;;
    hub:get_modules)
        hub_get_modules
        ;;
    hub:module_config_options)
        hub_module_config_options
        ;;
    hub:module_action_outbounds)
        hub_module_action_outbounds
        ;;
    hub:hub_install_*)
        module_id="${action#hub_install_}"
        # Check if this module has a custom source registered
        custom_repo=""
        if [ -f "/etc/config/krot" ]; then
            custom_repo="$(uci -q get "krot.hub_source_${module_id}.repo" 2>/dev/null || true)"
        fi
        hub_install_module "$module_id" "$custom_repo"
        ;;
    hub:hub_remove_*)
        module_id="${action#hub_remove_}"
        hub_remove_module "$module_id"
        ;;
    *)
        updates_fail "${component:-unknown}" "${action:-unknown}" "Unknown component action"
        ;;
    esac
}

# Best-effort detection of the version a module actually has on the router.
# Priority: (1) the VERSION file the installer writes on every install/update,
# (2) live binary/package metadata, (3) nothing (the caller falls back to the
# module.json version). Keeps the LuCI Modules tab in sync with reality
# instead of hard-coded values in updater.sh or the manifests.
hub_detect_installed_version() {
    local component="$1"
    [ -n "$component" ] || return 0
    case "$component" in
        zapret)
            # The classic zapret package version comes from the package manager
            # only — the zapret2 provider installs to the same path but is a
            # different product with its own versioning.
            get_zapret_package_version 2>/dev/null
            ;;
        zapret2)
            # The zapret2 installer records the upstream release tag; fall back to
            # the provider binary so a hand-placed provider is still detected.
            [ -f /opt/zapret/VERSION.embedded ] && { head -n 1 /opt/zapret/VERSION.embedded 2>/dev/null; return 0; }
            # No embedded marker — query the binary directly so a manual
            # nfqws2 placement is still reported with its own version, not the
            # classic zapret package version.
            is_zapret_provider_available && {
                "$ZAPRET_PROVIDER_NFQWS_BIN" --version 2>/dev/null | sed -n '1s/^.*version[[:space:]]*//p' | awk '{print $1; exit}'
            }
            ;;
        byedpi)
            [ -f /opt/byedpi/VERSION ] && { head -n 1 /opt/byedpi/VERSION 2>/dev/null; return 0; }
            get_byedpi_package_version 2>/dev/null
            ;;
        adguard)
            [ -f /opt/AdGuardHome/VERSION ] && { head -n 1 /opt/AdGuardHome/VERSION 2>/dev/null; return 0; }
            /opt/AdGuardHome/AdGuardHome --version 2>/dev/null | head -n 1 \
                | sed 's/^AdGuard Home, version //; s/^v//'
            ;;
        olcrtc)
            [ -f /opt/olcrtc/VERSION ] && { head -n 1 /opt/olcrtc/VERSION 2>/dev/null; return 0; }
            ;;
        openflux)
            [ -f /opt/openflux/VERSION ] && { head -n 1 /opt/openflux/VERSION 2>/dev/null; return 0; }
            [ -f /usr/lib/krot-openflux/VERSION ] && head -n 1 /usr/lib/krot-openflux/VERSION 2>/dev/null
            ;;
        xray)
            [ -f /etc/xray/VERSION ] && { head -n 1 /etc/xray/VERSION 2>/dev/null; return 0; }
            [ -x /usr/bin/xray ] && /usr/bin/xray version 2>/dev/null | head -1 | awk '{print $2}'
            ;;
    esac
}

# Detect installed status of a hub module by its `component` field.
# Each module must declare `component` in module.json (e.g. "zapret", "byedpi", "adguard").
# Sets `hub_installed` (true|false) and `hub_installed_version` in the calling scope.
hub_module_installed_status() {
    local component="$1"
    hub_installed=false
    hub_installed_version=""
    case "$component" in
        zapret)
            # Only the classic zapret package counts for this module — the
            # zapret2 provider installs to the same /opt/zapret path but is a
            # different product with its own versioning.
            zapret_package_installed || return 1
            hub_installed_version="$(get_zapret_package_version 2>/dev/null || true)"
            ;;
        zapret2)
            # Zapret2 records its upstream release tag in VERSION.embedded at
            # install time. Fall back to the live binary only when the marker
            # file is missing (hand-placed provider).
            is_zapret_provider_available || return 1
            hub_installed_version="$(head -n 1 /opt/zapret/VERSION.embedded 2>/dev/null || true)"
            [ -n "$hub_installed_version" ] || {
                # No embedded marker — query the binary directly so a manual
                # nfqws2 placement is still reported with its own version,
                # not the classic zapret package version.
                hub_installed_version="$("$ZAPRET_PROVIDER_NFQWS_BIN" --version 2>/dev/null | sed -n '1s/^.*version[[:space:]]*//p' | awk '{print $1; exit}')"
            }
            ;;
        byedpi)
            is_byedpi_installed || return 1
            hub_installed_version="$(get_byedpi_package_version 2>/dev/null || true)"
            ;;
        adguard)
            is_adguard_installed || return 1
            # Installers write the exact release tag to /opt/AdGuardHome/VERSION;
            # the live binary output is the fallback for older installs.
            hub_installed_version="$(head -n 1 /opt/AdGuardHome/VERSION 2>/dev/null || true)"
            [ -n "$hub_installed_version" ] || \
                hub_installed_version="$(/opt/AdGuardHome/AdGuardHome --version 2>/dev/null | head -1 || true)"
            hub_installed_version="${hub_installed_version#AdGuard Home, version }"
            hub_installed_version="${hub_installed_version#v}"
            ;;
        olcrtc)
            is_olcrtc_installed || return 1
            hub_installed_version="$(get_olcrtc_version 2>/dev/null || true)"
            ;;
        openflux)
            is_openflux_installed || return 1
            hub_installed_version="$(get_openflux_version 2>/dev/null || true)"
            ;;
        xray)
            is_xray_installed || return 1
            hub_installed_version="$(get_xray_version 2>/dev/null || true)"
            ;;
        *)
            return 1
            ;;
    esac
    hub_installed=true
    return 0
}

# Whether AdGuard Home binary is present. Mirrors is_zapret_installed / is_byedpi_installed.
is_adguard_installed() {
    [ -x /opt/AdGuardHome/AdGuardHome ]
}

# Whether the olcRTC tunnel module is present: init script plus the srv binary
# installed by hub/olcrtc/install.sh.
is_olcrtc_installed() {
    [ -x /etc/init.d/olcrtc ] && [ -x /opt/olcrtc/olcrtc ]
}

# olcRTC srv has no --version flag; hub/olcrtc/install.sh writes the release
# tag it actually downloaded to /opt/olcrtc/VERSION, so the installed version
# is read from that file instead of being hard-coded here.
get_olcrtc_version() {
    head -n 1 /opt/olcrtc/VERSION 2>/dev/null || echo "installed"
}

# Whether the OpenFlux exit-node module is present. The 0.1.x layout kept the
# runner in /usr/lib/krot-openflux; 0.2.x keeps everything in /opt/openflux.
# The openflux binary itself is optional (upstream ships no Linux builds), so
# its absence does not make the module "not installed".
is_openflux_installed() {
    {
        [ -x /etc/init.d/krot-openflux ] && [ -x /opt/openflux/openflux-run.sh ]
    } || {
        [ -x /etc/init.d/krot-openflux ] && [ -x /usr/lib/krot-openflux/openflux-run.sh ]
    }
}

# The installer writes the module version to /opt/openflux/VERSION (0.2.x) or
# /usr/lib/krot-openflux/VERSION (0.1.x).
get_openflux_version() {
    head -n 1 /opt/openflux/VERSION 2>/dev/null \
        || head -n 1 /usr/lib/krot-openflux/VERSION 2>/dev/null \
        || echo "installed"
}

is_xray_installed() {
    [ -x /etc/init.d/xray ] && [ -x /usr/bin/xray ]
}

get_xray_version() {
    [ -f /etc/xray/VERSION ] && { head -n 1 /etc/xray/VERSION 2>/dev/null; return 0; }
    [ -x /usr/bin/xray ] && /usr/bin/xray version 2>/dev/null | head -1 | awk '{print $2}' || echo "installed"
}

# Path of the generated generic Hub manifest helper (ucode). K.R.O.T. is a
# wrapper: a Hub module declares everything about itself in module.json, and
# this helper only reshapes that declaration (embed a declared config template,
# list declared render targets). It knows no module ids and contains no
# per-module code, so a new module needs no backend change. The script lives in
# the updates temp dir instead of json_utils.uc so the Hub logic stays with the
# Hub engine; it is generated once per process and reused for every module.
hub_modules_ucode_script() {
    local script_path

    updates_init_tmp_dir || return 1
    script_path="$UPDATES_TMP_DIR/hub-modules.uc"
    [ -s "$script_path" ] && { printf '%s\n' "$script_path"; return 0; }

    cat > "$script_path" <<'HUB_MODULES_UCODE'
#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function read_text(path) {
    let data = fs.readfile(path);
    return data == null ? "" : data;
}

function read_json_file(path) {
    let data = read_text(path);
    if (data == "")
        return null;

    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function is_true(value) {
    return value === true || as_string(value) == "true" || value == 1;
}

// Drop the file's trailing newline(s) so an embedded template does not carry
// them into the UCI value the UI prefills from it.
function rstrip_newlines(text) {
    while (length(text) > 0) {
        let last = substr(text, length(text) - 1, 1);
        if (last != "\n" && last != "\r")
            break;
        text = substr(text, 0, length(text) - 1);
    }
    return text;
}

function module_actions(module) {
    return array_or_empty(module.actions);
}

let mode = ARGV[0] || "";

// list-templates <module_json_path>
// Prints the repo-relative template paths declared by this module, one per
// line, so the caller knows what to download. Nothing declared -> no output.
if (mode == "list-templates") {
    let module = read_json_file(ARGV[1]);
    if (type(module) != "object")
        exit(1);

    for (let action in module_actions(module)) {
        if (type(action) != "object")
            continue;

        let template = as_string(object_or_empty(action.config).template || "");
        if (template != "")
            print(template, "\n");
    }

    exit(0);
}

// inject-template <module_json_path> [<repo_template_path>=<local_file> ...]
// Embeds every downloaded template file into its declaring
// actions[].config.template_text. sprintf("%J") does the JSON escaping
// (backslashes, quotes, newlines, tabs, control chars), so the emitted object
// is always valid JSON; the caller keeps its own string if we exit non-zero.
if (mode == "inject-template") {
    let module = read_json_file(ARGV[1]);
    if (type(module) != "object")
        exit(1);

    let texts = {};
    let found = false;

    for (let i = 2; i < length(ARGV); i++) {
        let arg = as_string(ARGV[i]);
        let sep = index(arg, "=");
        if (sep < 0)
            continue;

        let text = rstrip_newlines(read_text(substr(arg, sep + 1)));
        if (text != "") {
            texts[substr(arg, 0, sep)] = text;
            found = true;
        }
    }

    if (!found)
        exit(1);

    for (let action in module_actions(module)) {
        if (type(action) != "object")
            continue;

        let config = object_or_empty(action.config);
        let template = as_string(config.template || "");
        if (template != "" && texts[template] != null) {
            config.template_text = texts[template];
            action.config = config;
        }
    }

    print(sprintf("%J", module), "\n");
    exit(0);
}

// usable_outbound <declared outbound_json>
// The sing-box outbound an action contributes, compacted to one line, or null
// when the declaration is unusable. Mirrors json_utils.uc valid-outbound: the
// document must be a JSON object carrying a non-empty "type" string, so the
// backend never receives a template it would have to reject at runtime. Both
// declared shapes are accepted — an object, or a string holding that object.
function usable_outbound(declared) {
    let value = declared;

    if (type(value) == "string") {
        if (value == "")
            return null;

        try {
            value = json(value);
        }
        catch (e) {
            return null;
        }
    }

    if (type(value) != "object" || type(value.type) != "string" || value.type == "")
        return null;

    return sprintf("%J", value);
}

// action-outbounds <modules_json_path>
// One TAB-separated row per rule action contributed by an installed module:
// action_id, outbound_json. This is what lets a rule that carries no
// outbound_json of its own still be routed through the JSON-outbound
// primitive: the module that declares the action is the only source of truth
// for the outbound, and K.R.O.T. stays a wrapper with no module knowledge.
// Actions whose declaration is unusable (see usable_outbound) are skipped.
if (mode == "action-outbounds") {
    for (let module in array_or_empty(read_json_file(ARGV[1]))) {
        if (type(module) != "object" || !is_true(module.installed))
            continue;

        for (let action in array_or_empty(module.actions)) {
            if (type(action) != "object")
                continue;

            let action_id = as_string(action.id || "");
            if (action_id == "")
                continue;

            let outbound = usable_outbound(action.outbound_json);
            if (outbound != null)
                print(action_id, "\t", outbound, "\n");
        }
    }

    exit(0);
}

// config-options <modules_json_path>
// One TAB-separated row per config declared by an installed module:
// module_id, action_id, option, render_path, render_service, render_dir,
// format, auto_port. Missing values print as empty fields so the column count
// is always 8.
if (mode == "config-options") {
    for (let module in array_or_empty(read_json_file(ARGV[1]))) {
        if (type(module) != "object" || !is_true(module.installed))
            continue;

        let module_id = as_string(module.id || "");
        if (module_id == "")
            continue;

        for (let action in array_or_empty(module.actions)) {
            if (type(action) != "object")
                continue;

            let config = object_or_empty(action.config);
            let option = as_string(config.option || "");
            if (option == "")
                continue;

            print(module_id, "\t", as_string(action.id || ""), "\t", option, "\t",
                  as_string(config.render_path || ""), "\t", as_string(config.render_service || ""), "\t",
                  as_string(config.render_dir || ""), "\t", as_string(config.format || "none"), "\t",
                  is_true(config.auto_port) ? "true" : "false", "\n");
        }
    }

    exit(0);
}

warn("Usage: hub-modules.uc <inject-template|action-outbounds|config-options> ...\n");
exit(1);
HUB_MODULES_UCODE

    printf '%s\n' "$script_path"
}

hub_get_modules() {
    local hub_repo="${PODKOP_RELEASE_REPO:-titovcode/krot}"
    local _cache_ts; _cache_ts="$(date +%s)"
    local index_url="https://raw.githubusercontent.com/${hub_repo}/main/hub/index.json?v=${_cache_ts}"
    local tmp_index tmp_module module_ids module_id module_json_url
    local module_json module_component installed installed_version installed_version_escaped installed_json module_manifest_version latest_version_escaped first=1 result="["
    local injected_json cached

    # Serve the recent listing when one exists: this function performs one
    # HTTPS request per module, and LuCI calls it on every page build. Set
    # KROT_HUB_CACHE_TTL=0 to force a fresh fetch (the Modules tab does that
    # through hub_refresh_modules_cache).
    if [ "$HUB_CACHE_MAX_AGE" -gt 0 ] && cached="$(hub_cache_read)"; then
        printf '%s\n' "$cached"
        return 0
    fi

    updates_init_tmp_dir || { echo "[]"; return 1; }
    tmp_index="$UPDATES_TMP_DIR/hub-index.json"

    updates_log "Fetching hub index from ${index_url}"
    updates_http_get "$index_url" > "$tmp_index" 2>/dev/null

    if [ ! -s "$tmp_index" ]; then
        echo "[]"
        return 0
    fi

    module_ids="$(sed 's/.*"modules"[[:space:]]*:[[:space:]]*\[//;s/\].*//' "$tmp_index" 2>/dev/null | tr -d '"' | tr ',' ' ')"

    for module_id in $module_ids; do
        # Strip whitespace safely (busybox `tr` does not understand `[:space:]`).
        while [ "${module_id# }" != "$module_id" ]; do
            module_id="${module_id# }"
        done
        while [ "${module_id% }" != "$module_id" ]; do
            module_id="${module_id% }"
        done
        [ -z "$module_id" ] && continue
        # module_id goes into URLs and temp file names — reject anything but
        # the documented id charset ([A-Za-z0-9_-]) coming from index.json.
        case "$module_id" in
            *[!A-Za-z0-9_-]*) continue ;;
        esac

        tmp_module="$UPDATES_TMP_DIR/hub-${module_id}.json"
        module_json_url="https://raw.githubusercontent.com/${hub_repo}/main/hub/${module_id}/module.json?v=${_cache_ts}"

        updates_http_get "$module_json_url" > "$tmp_module" 2>/dev/null

        if [ -s "$tmp_module" ]; then
            # Reject invalid module.json so a broken upstream manifest does
            # not corrupt the whole modules response.
            json_utils_ucode file-json-valid "$tmp_module" >/dev/null 2>&1 || continue
            [ "$first" -eq 0 ] && result="${result},"
            # Compact JSON: strip newlines and tabs. Do NOT collapse spaces:
            # sed 's/  */ /g' corrupted double spaces inside string values.
            module_json="$(tr -d '\n\r\t' < "$tmp_module")"
            # Manifest version = what upstream currently offers (latest_version
            # for the UI update badge). Installed state is detected separately.
            module_manifest_version="$(printf '%s' "$module_json" | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"version"[[:space:]]*:[[:space:]]*"//;s/"$//')"
            # Determine installed status for this module via its declared `component`.
            module_component="$(printf '%s' "$module_json" | sed -n 's/.*"component"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
            if hub_module_installed_status "$module_component"; then
                # Escape for JSON: backslashes first, then double quotes.
                installed_version_escaped="${hub_installed_version//\\/\\\\}"
                installed_version_escaped="${installed_version_escaped//\"/\\\"}"
                installed_json=",\"installed\":true,\"installed_version\":\"${installed_version_escaped}\""
            else
                installed_json=",\"installed\":false,\"installed_version\":\"\""
            fi
            if [ -n "$module_manifest_version" ]; then
                latest_version_escaped="${module_manifest_version//\\/\\\\}"
                latest_version_escaped="${latest_version_escaped//\"/\\\"}"
                installed_json="${installed_json},\"latest_version\":\"${latest_version_escaped}\""
            fi

            # Resolve web_url template ({{router_ip}} -> actual LAN IP) so the
            # Hub page can deep-link to the module's own web panel from any
            # router. If we can't determine the LAN IP, fall back to "router".
            local web_url_raw web_url_resolved router_ip
            # Use Python-style non-greedy match by stopping at the FIRST
            # closing quote after the field. The previous `.*"..."` form
            # was greedy: when the merged JSON already contained our own
            # injected `web_url` (from a previous pass), sed would pick
            # that one up instead of the raw `{{router_ip}}` from
            # module.json, leading to URLs like `http://1.2.3.4:3000/1.2.3.4`.
            web_url_raw="$(printf '%s' "$module_json" \
                | grep -o '"web_url"[[:space:]]*:[[:space:]]*"[^"]*"' \
                | head -1 \
                | sed 's/.*"web_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
            if [ -n "$web_url_raw" ]; then
                router_ip="$(uci -q get network.lan.ipaddr 2>/dev/null || true)"
                [ -n "$router_ip" ] || router_ip="router"
                # Use shell parameter expansion to avoid issues with sed delimiter
                # collisions inside the URL (e.g. https://, /path, query strings).
                # Try both ${router_ip} and {{router_ip}} forms.
                web_url_resolved="${web_url_raw//\$\{router_ip\}/$router_ip}"
                web_url_resolved="${web_url_resolved//\{\{router_ip\}\}/$router_ip}"
                # Escape for JSON: backslashes, then double quotes
                web_url_resolved="${web_url_resolved//\\/\\\\}"
                web_url_resolved="${web_url_resolved//\"/\\\"}"
                installed_json="${installed_json},\"web_url\":\"${web_url_resolved}\""
            fi

            # Inject installed / installed_version / web_url as the last properties of the object.
            # Strip trailing whitespace, then the final `}`, so we can append new fields.
            # Done with POSIX parameter expansion (no sed regex) so that '$' / '&' / '}'
            # characters inside installed_version don't break the substitution.
            #
            # Also drop any pre-existing `web_url` from module_json: we resolve
            # it above and inject the resolved value via installed_json. Without
            # this removal the output object would have two `web_url` fields —
            # the raw `{{router_ip}}` template plus our resolved URL — and
            # `JSON.parse` in the browser would pick whichever it sees first.
            module_json="$(printf '%s' "$module_json" \
                | sed 's/,"web_url"[[:space:]]*:[[:space:]]*"[^"]*"//g' \
                | sed 's/"web_url"[[:space:]]*:[[:space:]]*"[^"]*",//g')"
            stripped="$module_json"
            while [ "${stripped# }" != "$stripped" ]; do
                stripped="${stripped# }"
            done
            case "$stripped" in
                *"}")
                    body="${stripped%\}}"
                    ;;
                *)
                    body="$stripped"
                    ;;
            esac
            module_json="${body}${installed_json}}"

            # Embed the config templates this module declares
            # (actions[].config.template -> actions[].config.template_text) so
            # the rule editor can prefill a module-provided option. Best
            # effort: a module with no declared template, an offline router or
            # a missing helper keeps the manifest exactly as it was above.
            injected_json="$(hub_embed_module_templates "$hub_repo" "$_cache_ts" "$module_id" "$module_json" 2>/dev/null || true)"
            [ -n "$injected_json" ] && module_json="$injected_json"

            result="${result}${module_json}"
            first=0
        fi
    done

    result="${result}]"
    echo "$result"

    # Remember the fresh listing so the next caller (LuCI rebuilds the module
    # list on every page view) does not repeat the downloads.
    hub_cache_write "$result"
}

# Where the Hub listing is cached between calls, and how long it stays valid.
# The LuCI rule editor asks for the module list each time the page is built, so
# an uncached listing means one HTTPS request per module — seconds of
# "Loading view..." on a router.
hub_cache_write() {
    [ -n "$1" ] || return 0
    # Never cache an empty listing. "[]" is what a failed index fetch produces
    # (see hub_get_modules), and K.R.O.T. reaches the network through itself, so
    # at boot the request legitimately fails before the uplink is up. Caching
    # that failure for HUB_CACHE_MAX_AGE hides every Hub module for an hour -
    # and a rule whose action is provided by a module then has no outbound to
    # resolve, which used to take the whole service down.
    case "$1" in
    "[]") return 0 ;;
    esac
    printf '%s\n' "$1" > "$HUB_CACHE_FILE" 2> /dev/null || true
}

# Echo the cached listing when it is still fresh, otherwise nothing. Cache
# entries older than HUB_CACHE_MAX_AGE are treated as absent so a module
# published upstream still shows up after the window; the Modules tab's
# explicit refresh calls hub_refresh_modules_cache(), which bypasses this.
hub_cache_read() {
    local age now

    [ -s "$HUB_CACHE_FILE" ] || return 1

    now="$(date +%s)"
    age="$((now - $(hub_cache_mtime)))"
    [ "$age" -ge 0 ] && [ "$age" -lt "$HUB_CACHE_MAX_AGE" ] || return 1

    cat "$HUB_CACHE_FILE"
}

hub_cache_mtime() {
    date -r "$HUB_CACHE_FILE" +%s 2> /dev/null || echo 0
}

hub_refresh_modules_cache() {
    # Regenerate the Hub listing after a module install/remove so LuCI's
    # Modules tab shows the new state without forcing a full update.
    # Because it delegates to hub_get_modules, the cache carries the injected
    # actions[].config.template_text as well — that is what lets a render
    # lookup reuse the cache instead of refetching every template.
    #
    # The read cache is disabled for this call: a refresh exists precisely to
    # bypass it.
    local modules_json

    HUB_CACHE_MAX_AGE=0
    modules_json="$(hub_get_modules 2>/dev/null)" || return 0
    HUB_CACHE_MAX_AGE=3600
    [ -n "$modules_json" ] || return 0
    hub_cache_write "$modules_json"
}

# Download the config templates declared by one module manifest
# (actions[].config.template) and merge them into that manifest as
# actions[].config.template_text. The rewritten module object goes to stdout.
# Returns 1 without output when the module declares no template, the download
# fails or ucode is unavailable; the caller then keeps the manifest untouched,
# so a template problem can never break the Hub listing.
hub_embed_module_templates() {
    local hub_repo="$1"
    local cache_ts="$2"
    local module_id="$3"
    local module_json="$4"
    local helper manifest_file template_paths template_path template_file
    local template_url inject_args="" injected_json template_index=0

    helper="$(hub_modules_ucode_script)" || return 1
    updates_command_exists ucode || return 1

    manifest_file="$UPDATES_TMP_DIR/hub-${module_id}-inject.json"
    printf '%s' "$module_json" > "$manifest_file" 2>/dev/null || return 1

    template_paths="$(ucode "$helper" list-templates "$manifest_file" 2>/dev/null)" || return 1
    [ -n "$template_paths" ] || return 1

    for template_path in $template_paths; do
        # Only a plain repo-relative path below hub/ may be fetched, and the
        # path is interpolated into a raw.githubusercontent.com URL, so reject
        # anything outside the documented charset.
        case "$template_path" in
            hub/*)
                ;;
            *)
                continue
                ;;
        esac
        case "$template_path" in
            *[!A-Za-z0-9._/-]*)
                continue
                ;;
        esac

        template_file="$UPDATES_TMP_DIR/hub-${module_id}-template-${template_index}.json"
        template_index=$((template_index + 1))
        template_url="https://raw.githubusercontent.com/${hub_repo}/main/${template_path}?v=${cache_ts}"

        # A template that cannot be fetched is simply not injected.
        updates_http_get "$template_url" > "$template_file" 2>/dev/null || {
            rm -f "$template_file"
            continue
        }
        [ -s "$template_file" ] || {
            rm -f "$template_file"
            continue
        }

        # Unquoted on purpose: the charset above guarantees the accumulated
        # "<path>=<file>" tokens contain no whitespace to split on.
        inject_args="${inject_args} ${template_path}=${template_file}"
    done

    [ -n "$inject_args" ] || return 1

    # ucode is not built with shell trace checking, so the tokens are passed
    # unquoted by design (see the comment above).
    # shellcheck disable=SC2086
    injected_json="$(ucode "$helper" inject-template "$manifest_file" $inject_args 2>/dev/null | tr -d '\n\r\t')" || return 1
    [ -n "$injected_json" ] || return 1

    updates_log "Embedded hub config templates for ${module_id}" "debug"
    printf '%s\n' "$injected_json"
}

# List the module-provided config declarations of the installed Hub modules,
# one TAB-separated row per declaration:
#   module_id  action_id  option  render_path  render_service  render_dir  format  auto_port
# K.R.O.T. stays a wrapper: nothing here knows any module — the rows are read
# straight from what each module.json declares (via the generic helper), and
# the caller (/usr/bin/krot) uses them to find the render target for a rule
# option. An absent render_service init script is not checked; the declaration
# is reported as-is. Reads the /tmp cache written by hub_refresh_modules_cache
# and falls back to a fresh hub_get_modules listing when it is missing.
#
# This is also reached from entry points that install no EXIT cleanup (the
# daemon's show_config/reload paths after `start()` has cleared its trap, and
# `krot get_module_config_template`), so it guards its own working directory.
# Inside component_action() the directory already exists, and hub_guarded_call
# then leaves it for that trap to remove.
hub_module_config_options() {
    hub_guarded_call _hub_module_config_options "$@"
}

_hub_module_config_options() {
    local cache_file="${1:-/tmp/krot-hub-modules.json}"
    local helper

    if [ ! -s "$cache_file" ]; then
        # hub_refresh_modules_cache always writes the standard path, so a
        # caller-provided cache is regenerated directly.
        if [ "$cache_file" = "/tmp/krot-hub-modules.json" ]; then
            hub_refresh_modules_cache
        else
            hub_get_modules > "$cache_file" 2>/dev/null || true
        fi
    fi
    [ -s "$cache_file" ] || return 0

    helper="$(hub_modules_ucode_script)" || return 0
    updates_command_exists ucode || return 0

    ucode "$helper" config-options "$cache_file" 2>/dev/null || true
    return 0
}

# List the sing-box outbounds the installed Hub modules declare for their rule
# actions, one TAB-separated row per action:
#   action_id  outbound_json
# This is the fallback K.R.O.T. routes a rule through when the rule carries no
# outbound_json of its own (a rule written by hand, restored from a backup, or
# saved by a release whose UI did not copy the template yet). Reads the same
# /tmp cache as hub_module_config_options, so both callers share one Hub
# listing, and knows no module: the rows come straight from module.json.
hub_module_action_outbounds() {
    hub_guarded_call _hub_module_action_outbounds "$@"
}

_hub_module_action_outbounds() {
    local cache_file="${1:-/tmp/krot-hub-modules.json}"
    local helper

    if [ ! -s "$cache_file" ]; then
        if [ "$cache_file" = "/tmp/krot-hub-modules.json" ]; then
            hub_refresh_modules_cache
        else
            hub_get_modules > "$cache_file" 2>/dev/null || true
        fi
    fi
    [ -s "$cache_file" ] || return 0

    helper="$(hub_modules_ucode_script)" || return 0
    updates_command_exists ucode || return 0

    ucode "$helper" action-outbounds "$cache_file" 2>/dev/null || true
    return 0
}

# Fetch the outbound for a single action id straight from upstream, used when
# the cached Hub listing is unusable - most importantly at boot, when the
# listing request legitimately fails because K.R.O.T. has not brought the
# uplink up yet. Without this a rule using a module action silently stops
# working until something else happens to refresh the listing.
#
# The index is one small request; module manifests are only fetched for the
# modules it lists, and the ucode helper extracts the matching action. The
# result is deliberately NOT written to the listing cache: a hand-fetched subset
# would poison the cache with a partial listing that the Modules tab would then
# render as the complete set.
hub_fetch_action_outbound() {
    local action="$1"
    local hub_repo url index_file tmp_dir module_id manifest_file helper rows component
    local result="[" first=1

    [ -n "$action" ] || return 1
    # The action id ends up in URLs and file names.
    case "$action" in
    *[!A-Za-z0-9_-]*) return 1 ;;
    esac
    updates_command_exists ucode || return 1
    helper="$(hub_modules_ucode_script)" || return 1

    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/hub-action.XXXXXX" 2> /dev/null)" || return 1
    index_file="$tmp_dir/index.json"
    hub_repo="${PODKOP_RELEASE_REPO:-titovcode/krot}"
    url="https://raw.githubusercontent.com/${hub_repo}/main/hub/index.json?v=$(date +%s)"

    updates_http_get "$url" > "$index_file" 2>/dev/null || true
    if [ ! -s "$index_file" ]; then
        rm -rf "$tmp_dir" 2> /dev/null || true
        return 1
    fi

    for module_id in $(sed 's/.*"modules"[[:space:]]*:[[:space:]]*\[//;s/\].*//' "$index_file" 2> /dev/null |
        tr -d '"' | tr ',' ' '); do
        # busybox `tr` has no [:space:], so trim manually.
        while [ "${module_id# }" != "$module_id" ]; do module_id="${module_id# }"; done
        while [ "${module_id% }" != "$module_id" ]; do module_id="${module_id% }"; done
        [ -n "$module_id" ] || continue
        case "$module_id" in
        *[!A-Za-z0-9_-]*) continue ;;
        esac

        manifest_file="$tmp_dir/$module_id.json"
        updates_http_get \
            "https://raw.githubusercontent.com/${hub_repo}/main/hub/${module_id}/module.json?v=$(date +%s)" \
            > "$manifest_file" 2> /dev/null || true
        [ -s "$manifest_file" ] || continue
        json_utils_ucode file-json-valid "$manifest_file" > /dev/null 2>&1 || continue

        # Only consider modules that are actually installed here: a published
        # manifest is no proof that its component exists on this router, and
        # routing a rule through a module that is absent would point the
        # outbound at a service nobody starts.
        component="$(grep -o '"component"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest_file" |
            head -1 | sed 's/.*:[[:space:]]*"//; s/"$//')"
        [ -n "$component" ] || continue
        hub_module_installed_status "$component" || continue

        # hub-modules.uc reports actions only of modules marked installed. The
        # listing from hub_get_modules carries that flag, this hand-built one does
        # not, so it is added here - and the check above is what makes it true.
        [ "$first" -eq 0 ] && result="${result},"
        first=0
        result="${result}$(tr -d '\n\r\t' < "$manifest_file" | sed 's/^{/{"installed":true,/')"
    done
    result="${result}]"

    manifest_file="$tmp_dir/modules.json"
    printf '%s' "$result" > "$manifest_file" 2> /dev/null || {
        rm -rf "$tmp_dir" 2> /dev/null || true
        return 1
    }
    rows="$(ucode "$helper" action-outbounds "$manifest_file" 2> /dev/null)" || rows=""
    rm -rf "$tmp_dir" 2> /dev/null || true

    printf '%s\n' "$rows" | awk -F '\t' -v want="$action" '$1 == want { print $2; exit }' | grep . || return 1
    return 0
}

hub_add_source() {
    local source_arg="$1"
    local repo module_id branch

    # Parse "repo" or "repo@branch" or "repo module_id" format
    case "$source_arg" in
        *@*)
            repo="${source_arg%@*}"
            branch="${source_arg#*@}"
            ;;
        *)
            repo="$source_arg"
            branch="main"
            ;;
    esac

    # Validate repo format (owner/repo) and characters, since the value is
    # interpolated into raw.githubusercontent.com URLs.
    case "$repo" in
        */*)
            ;;
        *)
            updates_fail "hub" "add_source" "Invalid repo format: $repo (expected owner/repo)"
            return
            ;;
    esac
    case "$repo" in
        *[!A-Za-z0-9._/-]*)
            updates_fail "hub" "add_source" "Invalid characters in repo: $repo"
            return
            ;;
    esac
    case "$branch" in
        "" | *[!A-Za-z0-9._/-]*)
            updates_fail "hub" "add_source" "Invalid branch: $branch"
            return
            ;;
    esac

    # Fetch module.json to discover module_id
    local module_json_url="https://raw.githubusercontent.com/${repo}/${branch}/hub/index.json"
    local tmp_json

    updates_init_tmp_dir || { updates_fail "hub" "add_source" "Failed to create temp dir"; return; }
    tmp_json="$UPDATES_TMP_DIR/source-index.json"

    updates_log "Fetching index.json from ${module_json_url}"
    updates_http_get "$module_json_url" > "$tmp_json" 2>/dev/null

    if [ ! -s "$tmp_json" ]; then
        # Try single module format: repo has hub/{id}/module.json directly
        updates_fail "hub" "add_source" "Could not fetch index.json from ${repo}. Ensure the repo has hub/index.json or use a specific module."
        return
    fi

    # Parse module IDs from index.json
    local modules
    modules="$(grep -o '"modules"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$tmp_json" 2>/dev/null | grep -o '"[a-zA-Z0-9_-]*"' | tr -d '"')"

    if [ -z "$modules" ]; then
        updates_fail "hub" "add_source" "No modules found in ${repo}"
        return
    fi

    # Register each module as a UCI section
    local count=0
    for module_id in $modules; do
        # module_id becomes a UCI section name (hub_source_${module_id}) —
        # reject anything but the documented id charset ([A-Za-z0-9_-]).
        case "$module_id" in
            "" | *[!A-Za-z0-9_-]*)
                updates_log "Skipping invalid module id from source: ${module_id}" "debug"
                continue
                ;;
        esac
        local section="hub_source_${module_id}"
        uci -q delete "krot.${section}" 2>/dev/null || true
        uci -q set "krot.${section}=hub_source" 2>/dev/null
        uci -q set "krot.${section}.id=${module_id}" 2>/dev/null
        uci -q set "krot.${section}.repo=${repo}" 2>/dev/null
        uci -q set "krot.${section}.branch=${branch}" 2>/dev/null
        count=$((count + 1))
    done

    uci -q commit krot 2>/dev/null

    updates_success "hub" "add_source" "Added ${count} module(s) from ${repo}" "" "" 0 ""
}

hub_remove_source() {
    local source_arg="$1"
    local module_id repo

    case "$source_arg" in
        *@*)
            module_id="${source_arg%@*}"
            ;;
        *)
            module_id="$source_arg"
            ;;
    esac

    if [ -z "$module_id" ]; then
        updates_fail "hub" "remove_source" "Module id is required"
        return
    fi

    # Remove all sections matching this repo
    local removed=0
    for section in $(uci -q show krot 2>/dev/null | grep "hub_source" | cut -d. -f2 | sort -u); do
        local sid
        sid="$(uci -q get "krot.${section}.id" 2>/dev/null || true)"
        if [ "$sid" = "$module_id" ] || [ -z "$module_id" ]; then
            uci -q delete "krot.${section}" 2>/dev/null
            removed=$((removed + 1))
        fi
    done

    uci -q commit krot 2>/dev/null

    updates_success "hub" "remove_source" "Removed ${removed} source(s)" "" "" 0 ""
}

hub_list_sources() {
    local sources="[]"

    if [ -f "/etc/config/krot" ]; then
        sources="["
        local first=1
        for section in $(uci -q show krot 2>/dev/null | grep "hub_source" | cut -d. -f2 | sort -u); do
            local id repo branch
            id="$(uci -q get "krot.${section}.id" 2>/dev/null || true)"
            repo="$(uci -q get "krot.${section}.repo" 2>/dev/null || true)"
            branch="$(uci -q get "krot.${section}.branch" 2>/dev/null || true)"
            [ -z "$branch" ] && branch="main"
            if [ -n "$id" ] && [ -n "$repo" ]; then
                [ "$first" -eq 0 ] && sources="${sources},"
                sources="${sources}{\"id\":\"${id}\",\"repo\":\"${repo}\",\"branch\":\"${branch}\"}"
                first=0
            fi
        done
        sources="${sources}]"
    fi

    echo "$sources"
}

hub_install_module() {
    local module_id="$1"
    local custom_repo="$2"
    local hub_repo branch module_json_url module_json script_url tmp_dir tmp_script

    case "$module_id" in
        *[^a-zA-Z0-9_-]*)
            updates_fail "hub" "hub_install_${module_id}" "Invalid module id: $module_id"
            return
            ;;
    esac

    updates_init_tmp_dir || updates_fail "hub" "hub_install_${module_id}" "Failed to create temp dir"
    tmp_dir="$UPDATES_TMP_DIR"

    # Determine repo: custom_repo arg > PODKOP_RELEASE_REPO env > default
    if [ -n "$custom_repo" ]; then
        hub_repo="$custom_repo"
    else
        hub_repo="${PODKOP_RELEASE_REPO:-titovcode/krot}"
    fi

    # Check if this is a custom source with a branch
    branch=""
    if [ -f "/etc/config/krot" ]; then
        branch="$(uci -q get "krot.hub_source_${module_id}.branch" 2>/dev/null || true)"
    fi
    branch="${branch:-main}"

    # Try to fetch module.json to discover install_script path
    module_json_url="https://raw.githubusercontent.com/${hub_repo}/${branch}/hub/${module_id}/module.json"
    tmp_module_json="$tmp_dir/${module_id}-module.json"

    updates_log "Fetching module.json for ${module_id} from ${module_json_url}"
    if updates_http_get "$module_json_url" > "$tmp_module_json" 2>/dev/null && [ -s "$tmp_module_json" ]; then
        # Extract install_script path from module.json (simple grep, no jq dependency)
        script_path="$(grep -o '"install_script"[[:space:]]*:[[:space:]]*"[^"]*"' "$tmp_module_json" 2>/dev/null | sed 's/.*"install_script"[[:space:]]*:[[:space:]]*"//;s/"$//')"
    fi

    # Fallback to default path if module.json fetch failed or install_script not found
    if [ -z "$script_path" ]; then
        script_path="hub/${module_id}/install.sh"
    fi

    script_url="https://raw.githubusercontent.com/${hub_repo}/${branch}/${script_path}"
    tmp_script="$tmp_dir/${module_id}-install.sh"

    updates_log "Downloading install script for ${module_id} from ${script_url}"
    updates_http_get "$script_url" > "$tmp_script" 2>/dev/null \
        || updates_fail "hub" "hub_install_${module_id}" "Failed to download install script for ${module_id}"

    [ -s "$tmp_script" ] \
        || updates_fail "hub" "hub_install_${module_id}" "Install script for ${module_id} is empty"

    local script_log="$UPDATES_TMP_DIR/${module_id}-install.log"
    sh "$tmp_script" > "$script_log" 2>&1
    local script_rc=$?
    if [ "$script_rc" -ne 0 ]; then
        updates_log "Install script output:" "debug"
        tail -20 "$script_log" 2>/dev/null | while IFS= read -r line; do
            updates_log "  ${line}" "debug"
        done
        updates_fail "hub" "hub_install_${module_id}" "Install script for ${module_id} failed (exit code ${script_rc})"
    fi

    # Report the version actually present on the router after the install
    # script ran (it may have picked a newer release than the manifest), not
    # the static module.json value. VERSION-file / live detection first,
    # manifest version only as a last-resort fallback.
    local installed_version="" detected_version="" module_component=""
    if [ -s "$tmp_module_json" ]; then
        module_component="$(grep -o '"component"[[:space:]]*:[[:space:]]*"[^"]*"' "$tmp_module_json" 2>/dev/null | head -1 | sed 's/.*"component"[[:space:]]*:[[:space:]]*"//;s/"$//')"
    fi
    if [ -n "$module_component" ]; then
        detected_version="$(hub_detect_installed_version "$module_component" 2>/dev/null || true)"
        if [ -z "$detected_version" ] && hub_module_installed_status "$module_component" >/dev/null 2>&1; then
            detected_version="$hub_installed_version"
        fi
        if [ -n "$detected_version" ]; then
            installed_version="$detected_version"
        fi
    fi
    if [ -z "$installed_version" ] && [ -s "$tmp_module_json" ]; then
        installed_version="$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$tmp_module_json" 2>/dev/null | head -1 | sed 's/.*"version"[[:space:]]*:[[:space:]]*"//;s/"$//')"
    fi

    # Restart K.R.O.T. to pick up any UCI changes the install script made
    # (e.g. dns_server, dns_type, outbounds). Use restart (not reload) —
    # sing-box needs to fully rebuild its config.
    if [ -x /etc/init.d/krot ]; then
        updates_log "Restarting K.R.O.T. after ${module_id} install"
        /etc/init.d/krot restart 2>/dev/null || true
    fi

    # Refresh the cached hub module list so LuCI shows the new state
    # without requiring a full K.R.O.T. update.
    hub_refresh_modules_cache

    updates_success "hub" "hub_install_${module_id}" "${module_id} has been installed" "" "$installed_version" 1 "latest"
}

# Disable all rules that use a given action. Called when a module is removed
# so the router does not keep failing on rules that reference a now-missing
# action. Sets enabled='0' for every rule with the matching action.
hub_disable_rules_with_action() {
    local target_action="$1"
    local section action enabled changed=0

    [ -n "$target_action" ] || return 0

    # Load UCI config if not already loaded
    config_load krot 2>/dev/null || return 0

    # Iterate over all sections
    local section
    for section in $(uci -q show krot | grep "=section" | cut -d. -f2 | cut -d= -f1); do
        action="$(uci -q get "krot.${section}.action" 2>/dev/null || true)"
        enabled="$(uci -q get "krot.${section}.enabled" 2>/dev/null || echo '0')"
        
        if [ "$action" = "$target_action" ] && [ "$enabled" = "1" ]; then
            updates_log "Disabling rule '${section}' (action '${target_action}' no longer available)"
            uci -q set "krot.${section}.enabled=0" 2>/dev/null || true
            changed=1
        fi
    done

    if [ "$changed" -eq 1 ]; then
        uci -q commit krot 2>/dev/null || true
        updates_log "Disabled rules using action '${target_action}'"
    fi

    return 0
}

hub_remove_module() {
    local module_id="$1"
    local pkg_name=""

    case "$module_id" in
        *[^a-zA-Z0-9_-]*)
            updates_fail "hub" "hub_remove_${module_id}" "Invalid module id: $module_id"
            return
            ;;
    esac

    local tmp_dir
    updates_init_tmp_dir \
        || { updates_fail "hub" "hub_remove_${module_id}" "Failed to create temp dir"; return; }
    tmp_dir="$UPDATES_TMP_DIR"

    # Try to download the module's remove.sh from GitHub (preferred path).
    # Falls back to the built-in package-based handler for the legacy
    # zapret/byedpi cases.
    # Use the same source resolution as hub_install_module: a custom source
    # registered via hub_add_source takes precedence over the default repo.
    local hub_repo branch
    hub_repo="$(uci -q get "krot.hub_source_${module_id}.repo" 2>/dev/null || true)"
    hub_repo="${hub_repo:-${PODKOP_RELEASE_REPO:-titovcode/krot}}"
    branch="$(uci -q get "krot.hub_source_${module_id}.branch" 2>/dev/null || true)"
    branch="${branch:-main}"

    local tmp_module_json="$tmp_dir/${module_id}-module.json"
    local module_json_url="https://raw.githubusercontent.com/${hub_repo}/${branch}/hub/${module_id}/module.json"
    updates_http_get "$module_json_url" > "$tmp_module_json" 2>/dev/null || true

    local remove_script_path=""
    if [ -s "$tmp_module_json" ]; then
        remove_script_path="$(grep -o '"remove_script"[[:space:]]*:[[:space:]]*"[^"]*"' "$tmp_module_json" 2>/dev/null | sed 's/.*"remove_script"[[:space:]]*:[[:space:]]*"//;s/"$//')"
    fi

    if [ -n "$remove_script_path" ]; then
        # Custom remove script path is declared in module.json
        local script_url="https://raw.githubusercontent.com/${hub_repo}/${branch}/${remove_script_path}"
        local tmp_script="$tmp_dir/${module_id}-remove.sh"
        updates_log "Downloading remove script for ${module_id} from ${script_url}"
        updates_http_get "$script_url" > "$tmp_script" 2>/dev/null \
            || { updates_fail "hub" "hub_remove_${module_id}" "Failed to download remove script for ${module_id}"; return; }

        [ -s "$tmp_script" ] \
            || { updates_fail "hub" "hub_remove_${module_id}" "Remove script for ${module_id} is empty"; return; }

        local script_log="$tmp_dir/${module_id}-remove.log"
        sh "$tmp_script" > "$script_log" 2>&1
        local script_rc=$?
        if [ "$script_rc" -ne 0 ]; then
            updates_log "Remove script output:" "debug"
            tail -20 "$script_log" 2>/dev/null | while IFS= read -r line; do
                updates_log "  ${line}" "debug"
            done
            updates_fail "hub" "hub_remove_${module_id}" "Remove script for ${module_id} failed (exit code ${script_rc})"
            return
        fi

        # Disable any rules using actions declared by this module
        if [ -s "$tmp_module_json" ]; then
            local module_actions
            module_actions="$(grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' "$tmp_module_json" 2>/dev/null | sed 's/.*"id"[[:space:]]*:[[:space:]]*"//;s/"$//' | grep -v "^${module_id}$" || true)"
            for action_id in $module_actions; do
                [ -n "$action_id" ] && hub_disable_rules_with_action "$action_id"
            done
        fi

        # Restart K.R.O.T. to pick up the changed UCI state. Use restart
        # (not just reload) — the install/remove script may have flipped
        # dns_server / dns_type, and sing-box needs to fully rebuild.
        if [ -x /etc/init.d/krot ]; then
            updates_log "Restarting K.R.O.T. after ${module_id} removal"
            /etc/init.d/krot restart 2>/dev/null || true
        fi

        # Refresh the cached hub module list so LuCI shows the new state
        # without requiring a full K.R.O.T. update.
        hub_refresh_modules_cache

        updates_success "hub" "hub_remove_${module_id}" "${module_id} has been removed" "" "" 0 ""
        return
    fi

    # No custom remove script — fall back to built-in package handler
    case "$module_id" in
        zapret)
            pkg_name="zapret"
            if [ -x /etc/init.d/zapret ]; then
                updates_log "Stopping zapret service"
                /etc/init.d/zapret stop 2>/dev/null || true
                /etc/init.d/zapret disable 2>/dev/null || true
            fi
            ;;
        zapret2)
            # zapret2 installs to /opt/zapret, same path as classic zapret.
            # Remove the provider files and stop any running instances.
            updates_log "Removing zapret2 provider from /opt/zapret"
            pkill -f "nfqws2" 2>/dev/null || true
            pkill -f "/opt/zapret/nfq/nfqws" 2>/dev/null || true
            rm -rf /opt/zapret
            rm -rf /var/run/krot/zapret /tmp/krot/zapret 2>/dev/null || true
            # Disable any rules still using the zapret action
            hub_disable_rules_with_action "zapret"
            # Restart K.R.O.T. to clean up nft rules
            if [ -x /etc/init.d/krot ]; then
                updates_log "Restarting K.R.O.T. after zapret2 removal"
                /etc/init.d/krot restart 2>/dev/null || true
            fi
            hub_refresh_modules_cache
            updates_success "hub" "hub_remove_${module_id}" "${module_id} has been removed" "" "" 0 ""
            return
            ;;
        byedpi)
            pkg_name="byedpi"
            if [ -x /etc/init.d/byedpi ]; then
                updates_log "Stopping byedpi service"
                /etc/init.d/byedpi stop 2>/dev/null || true
                /etc/init.d/byedpi disable 2>/dev/null || true
            fi
            ;;
        *)
            # Unknown module with no remove_script declared
            updates_log "No built-in remove handler for ${module_id}"
            updates_fail "hub" "hub_remove_${module_id}" "Remove not supported for ${module_id}"
            return
            ;;
    esac

    # Detect package format and remove
    if command -v apk >/dev/null 2>&1; then
        updates_log "Removing package ${pkg_name} via apk"
        apk del "$pkg_name" 2>/dev/null \
            || updates_fail "hub" "hub_remove_${module_id}" "Failed to remove ${pkg_name} via apk"
    else
        updates_log "Removing package ${pkg_name} via opkg"
        opkg remove "$pkg_name" 2>/dev/null \
            || updates_fail "hub" "hub_remove_${module_id}" "Failed to remove ${pkg_name} via opkg"
    fi

    # Restart K.R.O.T. to clean up nft/sing-box rules
    if [ -x /etc/init.d/krot ]; then
        updates_log "Restarting K.R.O.T. after ${module_id} removal"
        /etc/init.d/krot reload 2>/dev/null || true
    fi

    # Refresh the cached hub module list so LuCI shows the new state
    # without requiring a full K.R.O.T. update.
    hub_refresh_modules_cache

    updates_success "hub" "hub_remove_${module_id}" "${module_id} has been removed" "" "" 0 ""
}
