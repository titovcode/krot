#!/bin/sh
# Cross-build headless whitelist-bypass creators for router architectures.
#
# Run this on your desktop (Go 1.26+ required), then either:
#   a) copy the binaries to the router:  scp dist/krot-wlb/linux-<arch>/headless-*-creator root@router:/usr/lib/krot-wlb/bin/
#   b) or serve dist/krot-wlb over HTTP and install with WLB_BIN_BASE=http://<host>/linux-<arch>
#
# The upstream project already publishes CLI bundles for arm/mips in its
# GitHub releases, so this script is only needed for custom patches or
# architectures the upstream release does not cover.
#
# Usage: WLB_SRC=/path/to/whitelist-bypass ./build-binaries.sh [targets...]
#   targets: subset of "x64 ia32 arm64 arm mips mipsle mips64 mips64le" (default: all)
set -e

WLB_SRC="${WLB_SRC:-$(cd "$(dirname "$0")/../../../whitelist-bypass-main" 2>/dev/null && pwd)}"
if [ -z "$WLB_SRC" ] || [ ! -d "$WLB_SRC/headless" ]; then
    echo "Set WLB_SRC to a whitelist-bypass checkout (with headless/ inside)" >&2
    exit 1
fi

OUT="$(cd "$(dirname "$0")" && pwd)/dist/krot-wlb"
mkdir -p "$OUT"

TARGETS="${*:-x64 ia32 arm64 arm mips mipsle mips64 mips64le}"

PLATFORMS="vk telemost wbstream dion"

build() {
    label="$1"; goarch="$2"; extraenv="$3"
    dir="$OUT/linux-$label"
    mkdir -p "$dir"
    for p in $PLATFORMS; do
        bin="headless-$p-creator-linux-$label"
        echo "  $bin"
        # shellcheck disable=SC2086
        env GOOS=linux GOARCH="$goarch" $extraenv go -C "$WLB_SRC/headless/$p" build \
            -trimpath -ldflags="-s -w" -o "$dir/headless-$p-creator" .
        # Keep an arch-suffixed copy for HTTP hosting under WLB_BIN_BASE.
        cp "$dir/headless-$p-creator" "$dir/$bin"
    done
    if command -v upx >/dev/null 2>&1; then
        upx -q --best "$dir"/headless-*-creator 2>/dev/null || true
    fi
}

for t in $TARGETS; do
    echo "=== linux/$t ==="
    case "$t" in
        x64)     build x64 amd64 "" ;;
        ia32)    build ia32 386 "" ;;
        arm64)   build arm64 arm64 "" ;;
        arm)     build arm arm "GOARM=5" ;;
        mips)    build mips mips "GOMIPS=softfloat" ;;
        mipsle)  build mipsle mipsle "GOMIPS=softfloat" ;;
        mips64)  build mips64 mips64 "GOMIPS64=softfloat" ;;
        mips64le) build mips64le mips64le "GOMIPS64=softfloat" ;;
        *) echo "unknown target: $t" >&2; exit 1 ;;
    esac
done

echo ""
echo "Done. Output in $OUT:"
ls -lh "$OUT"/linux-*/headless-telemost-creator 2>/dev/null || true
