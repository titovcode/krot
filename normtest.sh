#!/bin/sh
# Test the exact normalization block used in fetch-binary.sh / install_binary()
BASE="${1:-}"
BASE="${BASE%/}"
case "$BASE" in
    */releases/tag/*) BASE="$(printf '%s' "$BASE" | sed 's,/releases/tag/,/releases/download/,')" ;;
esac
OF_RELEASE_REPO="titovcode/krot"; OF_TAG="openflux-0.1.0"
[ -n "$BASE" ] || BASE="https://github.com/${OF_RELEASE_REPO}/releases/download/${OF_TAG}"
echo "-> $BASE/openflux-linux-armv7"
