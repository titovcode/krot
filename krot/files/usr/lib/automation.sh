#!/bin/sh
# /usr/lib/krot/automation.sh — проверка latency и перезапуск интерфейсов

STATE_DIR="/var/run/krot/automation"
mkdir -p "$STATE_DIR" 2>/dev/null || true

. /lib/functions.sh

check_and_restart() {
    local section="$1"
    local enabled iface max_latency max_failures interval
    
    # Skip if K.R.O.T. is busy with reload or subscription update (prevents lock conflicts)
    [ -d /var/run/krot.reload.lock ] && return 0
    [ -d /var/run/krot/subscription-update.lock ] && return 0
    # component-action.lock is a directory created by mkdir; the -f test below
    # was dead code (it can never match a directory) and has been removed.
    [ -d /var/run/krot/component-action.lock ] && return 0
    
    config_get enabled "$section" automation_enabled "0"
    [ "$enabled" = "1" ] || return 0
    
    config_get iface "$section" interface ""
    [ -n "$iface" ] || return 0
    
    config_get max_latency "$section" automation_max_latency "1000"
    config_get max_failures "$section" automation_failures "3"
    config_get interval "$section" automation_interval "30"
    config_get port "$section" mixed_proxy_port "1080"
    
    # Strip quotes from config values (OpenWRT config_get returns quoted values)
    max_latency=$(echo "$max_latency" | tr -d "'\"")
    max_failures=$(echo "$max_failures" | tr -d "'\"")
    interval=$(echo "$interval" | tr -d "'\"")
    port=$(echo "$port" | tr -d "'\"")
    
    local state_file="$STATE_DIR/$section.fail_count"
    local last_check="$STATE_DIR/$section.last_check"
    
    # Measure latency
    local latency
    latency=$(measure_latency "$iface" "$port")
    
    if [ -z "$latency" ] || [ "$latency" -gt "$max_latency" ] 2>/dev/null; then
        local count=0
        [ -f "$state_file" ] && count=$(cat "$state_file" 2>/dev/null || echo 0)
        count=$((count + 1))
        echo "$count" > "$state_file" 2>/dev/null || true
        
        logger -t krot-automation "Rule '$section': latency ${latency:-timeout}ms exceeds ${max_latency}ms (failure $count/$max_failures)"
        
        if [ "$count" -ge "$max_failures" ]; then
            logger -t krot-automation "Rule '$section': restarting interface '$iface'"
            
            ifdown "$iface" >/dev/null 2>&1
            sleep 2
            ifup "$iface" >/dev/null 2>&1
            
            echo "0" > "$state_file" 2>/dev/null || true
            
            # Wait for interface and K.R.O.T. to stabilize (prevents "component action already running" errors)
            sleep 30

            # Remove stale locks left by the K.R.O.T. restart triggered by
            # ifdown/ifup. Only drop a lock whose owning process is gone, so a
            # reload/update that is still running keeps its lock.
            for lock_dir in /var/run/krot/component-action.lock \
                            /var/run/krot.reload.lock \
                            /var/run/krot/subscription-update.lock; do
                [ -d "$lock_dir" ] || continue
                lock_owner="$(sed -n '1p' "$lock_dir/pid" 2>/dev/null)"
                if [ -n "$lock_owner" ] && kill -0 "$lock_owner" 2>/dev/null; then
                    logger -t krot-automation "Rule '$section': lock $lock_dir still held by PID $lock_owner after restart; leaving it in place"
                    continue
                fi
                rm -rf "$lock_dir" 2>/dev/null || true
            done

            # Remove stale component action jobs (older than 5 minutes)
            find /var/run/krot/component-actions -name "*.json" -mmin +5 -delete 2>/dev/null || true
        fi
    else
        if [ -f "$state_file" ]; then
            local current
            current=$(cat "$state_file" 2>/dev/null || echo 0)
            if [ "$current" != "0" ]; then
                logger -t krot-automation "Rule '$section': recovered, latency ${latency}ms"
                echo "0" > "$state_file" 2>/dev/null || true
            fi
        fi
    fi
}

measure_latency() {
    local iface="$1"
    local port="$2"
    local result time_ms test_port
    
    # Try configured port first, then common Xray ports
    for test_port in "$port" "10808" "10809" "1080"; do
        [ -z "$test_port" ] && continue
        
        # Try curl directly - if port is closed, curl will fail quickly
        if command -v curl >/dev/null 2>&1; then
            result=$(curl -x "socks5h://127.0.0.1:$test_port" \
                          --connect-timeout 2 \
                          --max-time 4 \
                          -s \
                          -w "%{time_total}" \
                          -o /dev/null \
                          http://cp.cloudflare.com/ 2>/dev/null)
            
            # Check if we got a valid response with meaningful latency
            if [ -n "$result" ] && [ "$result" != "0.000" ]; then
                time_ms=$(echo "$result" | awk '{printf "%.0f", $1 * 1000}')
                # Sanity check: if latency is suspiciously low (< 10ms), it's probably local
                if [ "$time_ms" -gt 10 ]; then
                    echo "$time_ms"
                    return
                fi
            fi
        fi
    done
    
    # Fallback: if curl fails or no SOCKS, try direct ping through interface
    local endpoint
    if command -v awg >/dev/null 2>&1; then
        endpoint=$(awg show "$iface" endpoints 2>/dev/null | awk -F'\t' '{print $2}' | cut -d: -f1 | head -1)
    elif command -v wg >/dev/null 2>&1; then
        endpoint=$(wg show "$iface" endpoints 2>/dev/null | awk '{print $2}' | cut -d: -f1 | head -1)
    fi
    
    if [ -n "$endpoint" ] && [ "$endpoint" != "(none)" ]; then
        result=$(ping -c 3 -W 2 -I "$iface" "$endpoint" 2>/dev/null | tail -1)
        if [ -n "$result" ]; then
            echo "$result" | awk -F'/' '{print $5}' | cut -d. -f1
            return
        fi
    fi
    
    # Last resort: ping 8.8.8.8 through interface
    result=$(ping -c 3 -W 2 -I "$iface" 8.8.8.8 2>/dev/null | tail -1)
    if [ -n "$result" ]; then
        echo "$result" | awk -F'/' '{print $5}' | cut -d. -f1
        return
    fi
    
    echo ""
}

# Main execution
config_load krot
config_foreach check_and_restart section
