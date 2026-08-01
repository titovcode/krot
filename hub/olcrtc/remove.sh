#!/bin/sh
# olcRTC tunnel remover for K.R.O.T. Hub
set -e

if [ -x /etc/init.d/olcrtc ]; then
    /etc/init.d/olcrtc stop 2>/dev/null || true
    /etc/init.d/olcrtc disable 2>/dev/null || true
fi

rm -f /etc/init.d/olcrtc
rm -rf /opt/olcrtc
rm -rf /etc/olcrtc
rm -rf /www/olcrtc
rm -f /etc/config/olcrtc
rm -f /tmp/olcrtc

printf '\033[32m%s\033[0m\n' "olcrtc removed"
