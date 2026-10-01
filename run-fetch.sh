#!/bin/bash
# Run the REAL fetch-binary.sh against a sandbox, with the exact bin_base
# currently on the user's router.
SBOX=/tmp/fbtest/sandbox
rm -rf "$SBOX"; mkdir -p "$SBOX/opt/openflux"
# stub uci to return the user's actual (wrong) bin_base
cat > /tmp/fbtest/uci <<'UCI'
#!/bin/sh
[ "$2" = "get" ] && [ "$3" = "krot_openflux.settings.bin_base" ] && \
  echo "https://github.com/titovcode/krot/releases/tag/openflux-0.1.0"
UCI
chmod +x /tmp/fbtest/uci
export PATH="/tmp/fbtest:/usr/bin:/bin"
OF_DIR="$SBOX/opt/openflux"
OF_BIN="$OF_DIR/openflux"
sed -i '' 's#^OF_DIR="/opt/openflux"#OF_DIR="'"$OF_DIR"'"#' /tmp/fbtest/fetch-binary.sh 2>/dev/null || \
  sed -i 's#^OF_DIR="/opt/openflux"#OF_DIR="'"$OF_DIR"'"#' /tmp/fbtest/fetch-binary.sh
sed -i '' 's#^LOG="/tmp/openflux-fetch.log"#LOG="/tmp/fbtest/fetch.log"#' /tmp/fbtest/fetch-binary.sh 2>/dev/null || \
  sed -i 's#^LOG="/tmp/openflux-fetch.log"#LOG="/tmp/fbtest/fetch.log"#' /tmp/fbtest/fetch-binary.sh
echo "=== arch: $1 ==="
sh /tmp/fbtest/fetch-binary.sh 2>&1 | tail -6
if [ -x "$OF_BIN" ]; then echo "RESULT: INSTALLED ($(file "$OF_BIN" | cut -d, -f1 | sed 's/.*: //'))"; else echo "RESULT: NOT INSTALLED"; fi
