#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/nettle}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
VERSION=3.10.2
TARGET="${ALTITUDE_TARGET_TRIPLET:-x86_64-altitude-linux-gnu}"
TOOLCHAIN_ROOT="${ALTITUDE_TOOLCHAIN_ROOT:-}"
FORGE_ROOT="${ALTITUDE_FORGE_ROOT:-}"
TOOLCHAIN="$TOOLCHAIN_ROOT/opt/altitude/toolchain"
FORGE="$FORGE_ROOT/opt/altitude/forge"
SYSROOT="$TOOLCHAIN/sysroot"
CC="$TOOLCHAIN/bin/$TARGET-gcc"
AR="$TOOLCHAIN/bin/$TARGET-ar"
RANLIB="$TOOLCHAIN/bin/$TARGET-ranlib"
STRIP="$TOOLCHAIN/bin/$TARGET-strip"
MAKE="${FORGE}/bin/make"
PAYLOAD="$WORK/payload"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" nettle)"

export PATH="$FORGE/bin:$TOOLCHAIN/bin:$PATH"
export CPPFLAGS="${CPPFLAGS:-} -I$SYSROOT/usr/include"
export LDFLAGS="${LDFLAGS:-} -L$SYSROOT/usr/lib -Wl,-rpath-link,$SYSROOT/usr/lib"
export LD_LIBRARY_PATH="$SYSROOT/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

for tool in "$CC" "$AR" "$RANLIB" "$STRIP" "$MAKE"; do
  [ -x "$tool" ] || { echo "nettle: missing build tool: $tool" >&2; exit 1; }
done
[ -f "$SYSROOT/usr/include/gmp.h" ] || { echo "nettle: target dependency missing: gmp" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK/source" "$PAYLOAD/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

(
  cd "$WORK/source"
  CC="$CC" AR="$AR" RANLIB="$RANLIB" \
    ./configure --host="$TARGET" --prefix=/usr --libdir=/usr/lib \
      --enable-shared --disable-static --disable-documentation
  "$MAKE" -j"$JOBS"
  "$MAKE" DESTDIR="$PAYLOAD" install
)

find "$PAYLOAD/usr/lib" -name '*.la' -delete 2>/dev/null || true
find "$PAYLOAD/usr/lib" -type f -name '*.so*' -exec "$STRIP" --strip-unneeded {} + 2>/dev/null || true
install -d "$SYSROOT/usr"
cp -a "$PAYLOAD/usr/." "$SYSROOT/usr/"

{
  echo "Source: nettle"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: Autoconf shared cross $TARGET"
  echo "Compiler: $("$CC" --version | head -1)"
} > "$PAYLOAD/usr/share/altitude/sources/nettle.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/nettle/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-nettle-$VERSION-amd64.altpkg"
