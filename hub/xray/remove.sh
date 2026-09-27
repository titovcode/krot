#!/bin/sh
# Xray-core remover for K.R.O.T. Hub
set -e

if [ -x /etc/init.d/xray ]; then
    /etc/init.d/xray stop 2>/dev/null || true
    /etc/init.d/xray disable 2>/dev/null || true
fi

rm -f /etc/init.d/xray
rm -f /usr/bin/xray
# Drop the per-rule Xray fragments rendered by K.R.O.T. first. The rm -rf
# /etc/xray below already removes the directory itself along with everything
# in it — this explicit pass exists so that the fragments are gone even if
# /etc/xray ends up living somewhere else (e.g. on a different uci config_file)
# and never comes back as stale rule configs.
rm -f /etc/xray/conf.d/*.json 2>/dev/null || true
rm -rf /etc/xray
rm -f /etc/config/xray

if command -v opkg >/dev/null 2>&1; then
    if opkg list-installed | grep -q '^xray-core '; then
        opkg remove xray-core 2>/dev/null || true
    fi
fi

printf '\033[32m%s\033[0m\n' "Xray-core removed successfully"
printf '\033[33m%s\033[0m\n' "WARNING: rules still using the \"xray\" action keep their stored Xray JSON and their JSON outbound," >&2
printf '\033[33m%s\033[0m\n' "WARNING: but with the service gone they fall back to a plain SOCKS outbound to 127.0.0.1:10808" >&2
printf '\033[33m%s\033[0m\n' "WARNING: until they are edited and re-saved in K.R.O.T. -> Rules." >&2
