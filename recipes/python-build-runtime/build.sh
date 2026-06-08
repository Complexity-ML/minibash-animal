#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/python-build-runtime}"
PREFIX="/opt/altitude/forge"
VERSION=3.13.13
ABI_VERSION=3.13
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
TARGET="${ALTITUDE_TARGET_TRIPLET:-x86_64-altitude-linux-gnu}"
TOOLCHAIN_ROOT="${ALTITUDE_TOOLCHAIN_ROOT:-}"
TOOLCHAIN="$TOOLCHAIN_ROOT/opt/altitude/toolchain"
SYSROOT="$TOOLCHAIN/sysroot"
CC="${CC:-$TOOLCHAIN/bin/$TARGET-gcc}"
AR="${AR:-$TOOLCHAIN/bin/$TARGET-ar}"
RANLIB="${RANLIB:-$TOOLCHAIN/bin/$TARGET-ranlib}"
STRIP="${STRIP:-$TOOLCHAIN/bin/$TARGET-strip}"
PKG_CONFIG="${PKG_CONFIG:-/opt/altitude/forge/bin/pkg-config}"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" python-build-runtime)"

export PATH="$PREFIX/bin:$PATH"

for tool in "$CC" "$AR" "$RANLIB" "$STRIP"; do
  [ -x "$tool" ] || { echo "python-build-runtime: missing build tool: $tool" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/build" \
  "$WORK/payload/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

# Altitude's early libc header set can expose ssize_t without SSIZE_MAX.
# Keep Python bootstrap moving until the full base profile ships complete
# POSIX feature headers.
awk '
  $0 == "#   define PY_SSIZE_T_MAX SSIZE_MAX" {
    print "#   ifdef SSIZE_MAX"
    print "#     define PY_SSIZE_T_MAX SSIZE_MAX"
    print "#   else"
    print "#     define PY_SSIZE_T_MAX LONG_MAX"
    print "#   endif"
    next
  }
  { print }
' "$WORK/source/Include/pyport.h" > "$WORK/source/Include/pyport.h.altitude"
mv "$WORK/source/Include/pyport.h.altitude" "$WORK/source/Include/pyport.h"

(
  cd "$WORK/build"
  CC="$CC" AR="$AR" RANLIB="$RANLIB" \
  PKG_CONFIG="$PKG_CONFIG" \
  PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/lib64/pkgconfig:$SYSROOT/usr/share/pkgconfig" \
  PKG_CONFIG_SYSROOT_DIR="$SYSROOT" \
  CPPFLAGS="-I$SYSROOT/usr/include" \
  LDFLAGS="-L$SYSROOT/usr/lib64 -L$SYSROOT/usr/lib -Wl,-rpath,/opt/altitude/toolchain/sysroot/usr/lib64" \
    "$WORK/source/configure" \
    --prefix="$PREFIX" \
    --disable-test-modules \
    --without-ensurepip
  LD_LIBRARY_PATH="$SYSROOT/usr/lib64:$SYSROOT/usr/lib:$TOOLCHAIN/$TARGET/lib64:${LD_LIBRARY_PATH:-}" \
    make -j"$JOBS" CC="$CC" AR="$AR" RANLIB="$RANLIB"
  LD_LIBRARY_PATH="$SYSROOT/usr/lib64:$SYSROOT/usr/lib:$TOOLCHAIN/$TARGET/lib64:${LD_LIBRARY_PATH:-}" \
    make DESTDIR="$WORK/payload" altinstall
)

ln -sf "python$ABI_VERSION" "$WORK/payload$PREFIX/bin/python3"
ln -sf "python$ABI_VERSION" "$WORK/payload$PREFIX/bin/python"

# The forge is also the live build runtime for the next source recipes.
# Install the complete runtime immediately; the binary alone cannot import
# stdlib modules such as encodings.
if [ -d "$PREFIX/bin" ]; then
  cp -a "$WORK/payload$PREFIX/." "$PREFIX/"
  ln -sf "python$ABI_VERSION" "$PREFIX/bin/python3"
  ln -sf "python$ABI_VERSION" "$PREFIX/bin/python"
fi

find "$WORK/payload$PREFIX/bin" -type f -perm -0100 \
  -exec "$STRIP" --strip-unneeded {} + 2>/dev/null || true

{
  echo "Source: python-build-runtime"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: native forge runtime, no ensurepip or test modules"
  echo "Compiler: $("$CC" --version | head -1)"
} > "$WORK/payload/usr/share/altitude/sources/python-build-runtime.build"

LD_LIBRARY_PATH="$SYSROOT/usr/lib64:$SYSROOT/usr/lib:$TOOLCHAIN/$TARGET/lib64:${LD_LIBRARY_PATH:-}" \
  "$WORK/payload$PREFIX/bin/python3" -c \
  'import ctypes, curses, json, pathlib, ssl, subprocess, sys, uuid; assert sys.version_info[:2] == (3, 13)'

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/python-build-runtime/MANIFEST" "$WORK/payload" \
  "$OUT/altitude-python-build-runtime-$VERSION-amd64.altpkg"
