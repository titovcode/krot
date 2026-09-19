#!/bin/sh
# Cross-build the openflux Linux binary for router architectures.
#
# The upstream p1neappleXpress/OpenFlux releases ship Android/iOS builds only;
# Linux is expected to be built from source. This script compiles openflux
# statically (CGO disabled) for the usual OpenWrt targets and puts the results
# into ./dist. Host them anywhere (e.g. GitHub release of your fork) and set
# option bin_base in /etc/config/krot_openflux to the base URL.
#
# Usage:            sh build-binaries.sh [amd64|arm64|armv7|armv6|mipsle|mips|all]
# Requirements:     Go >= version from OpenFlux go.mod
#                   GOTOOLCHAIN auto-downloads the right toolchain when needed.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="${OF_SRC_DIR:-$HERE/OpenFlux}"
OUT_DIR="${OF_OUT_DIR:-$HERE/dist}"

clone_or_update_src() {
    if [ -d "$SRC_DIR/.git" ]; then
        git -C "$SRC_DIR" fetch --depth 1 origin main || true
        git -C "$SRC_DIR" reset --hard origin/main >/dev/null 2>&1 || true
    else
        rm -rf "$SRC_DIR"
        git clone --depth 1 https://github.com/p1neappleXpress/OpenFlux "$SRC_DIR"
    fi
}

build_one() {
    # build_one <goarch> <goarm|-> <label>
    local goarch="$1" goarm="$2" label="$3"
    echo "==> building openflux-linux-${label} (GOOS=linux GOARCH=${goarm#-}${goarch})"
    ( cd "$SRC_DIR" \
        && CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" GOARM="${goarm#-}" \
        go build -ldflags="-s -w" -trimpath -o "$OUT_DIR/openflux-linux-${label}" . )
    echo "==> built $OUT_DIR/openflux-linux-${label}"
}

build_target() {
    case "$1" in
        amd64)  build_one amd64 - amd64 ;;
        arm64)  build_one arm64 - arm64 ;;
        armv7)  build_one arm 7 armv7 ;;
        armv6)  build_one arm 6 armv6 ;;
        mipsle) build_one mipsle - mipsle ;;
        mips)   build_one mips - mips ;;
        mips64le) build_one mips64le - mips64le ;;
        *)
            echo "Unknown target: $1" >&2
            echo "Usage: $0 [amd64|arm64|armv7|armv6|mipsle|mips|mips64le|all]" >&2
            exit 1
            ;;
    esac
}

command -v go >/dev/null 2>&1 || { echo "Go is required (see https://go.dev/dl/)." >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git is required." >&2; exit 1; }

mkdir -p "$OUT_DIR"
clone_or_update_src

TARGET="${1:-all}"
if [ "$TARGET" = "all" ]; then
    for t in amd64 arm64 armv7 armv6 mipsle mips mips64le; do
        build_target "$t"
    done
else
    build_target "$TARGET"
fi

echo ""
echo "Done. Upload dist/openflux-linux-* to a host and set bin_base, e.g.:"
echo "  uci set krot_openflux.settings.bin_base='https://example.com/my-builds'"
