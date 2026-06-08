#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/openssl}"
VERSION=3.3.2
TARGET="${ALTITUDE_TARGET_TRIPLET:-x86_64-altitude-linux-gnu}"
TOOLCHAIN_ROOT="${ALTITUDE_TOOLCHAIN_ROOT:-}"
TOOLCHAIN="$TOOLCHAIN_ROOT/opt/altitude/toolchain"
SYSROOT="$TOOLCHAIN/sysroot"
CC="$TOOLCHAIN/bin/$TARGET-gcc"
AR="$TOOLCHAIN/bin/$TARGET-ar"
RANLIB="$TOOLCHAIN/bin/$TARGET-ranlib"
STRIP="$TOOLCHAIN/bin/$TARGET-strip"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" openssl)"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
PAYLOAD="$WORK/payload"

export PATH="/opt/altitude/forge/bin:$TOOLCHAIN/bin:$PATH"

for tool in "$CC" "$AR" "$RANLIB" "$STRIP"; do
  [ -x "$tool" ] || { echo "openssl: missing toolchain component: $tool" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/source" "$PAYLOAD/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

(
  cd "$WORK/source"
  CROSS_COMPILE="$TOOLCHAIN/bin/$TARGET-" \
    ./Configure linux-x86_64 \
      --prefix=/usr \
      --libdir=lib \
      --openssldir=/etc/ssl \
      shared no-tests no-docs
  make -j"$JOBS"
  make DESTDIR="$PAYLOAD" install_sw
)

find "$PAYLOAD/usr/lib" -name '*.la' -delete 2>/dev/null || true
find "$PAYLOAD/usr/lib" -type f -name '*.so*' -exec "$STRIP" --strip-unneeded {} + \
  2>/dev/null || true
find "$PAYLOAD/usr/bin" -type f -perm -0100 -exec "$STRIP" --strip-unneeded {} + \
  2>/dev/null || true

install -d "$SYSROOT/usr"
cp -a "$PAYLOAD/usr/." "$SYSROOT/usr/"

{
  echo "Source: openssl"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: shared cross $TARGET"
  echo "Compiler: $("$CC" --version | head -1)"
} > "$PAYLOAD/usr/share/altitude/sources/openssl.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/openssl/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-openssl-$VERSION-amd64.altpkg"
