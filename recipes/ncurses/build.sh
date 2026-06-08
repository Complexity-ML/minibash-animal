#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/ncurses}"
VERSION=6.5
TARGET="${ALTITUDE_TARGET_TRIPLET:-x86_64-altitude-linux-gnu}"
TOOLCHAIN_ROOT="${ALTITUDE_TOOLCHAIN_ROOT:-}"
TOOLCHAIN="$TOOLCHAIN_ROOT/opt/altitude/toolchain"
SYSROOT="$TOOLCHAIN/sysroot"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
CC="$TOOLCHAIN/bin/$TARGET-gcc"
AR="$TOOLCHAIN/bin/$TARGET-ar"
RANLIB="$TOOLCHAIN/bin/$TARGET-ranlib"
STRIP="$TOOLCHAIN/bin/$TARGET-strip"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" ncurses)"

export PATH="/opt/altitude/forge/bin:$PATH"

for tool in "$CC" "$AR" "$RANLIB" "$STRIP"; do
  [ -x "$tool" ] || { echo "ncurses: missing toolchain component: $tool" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/build" \
  "$WORK/payload/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

(
  cd "$WORK/build"
  CC="$CC" AR="$AR" RANLIB="$RANLIB" \
  CFLAGS="-O2 -pipe" \
    "$WORK/source/configure" \
      --build="$("$WORK/source/config.guess")" \
      --host="$TARGET" \
      --prefix=/usr \
      --libdir=/usr/lib \
      --with-build-cc="$CC" \
      --with-shared \
      --with-normal \
      --without-debug \
      --disable-stripping \
      --disable-db-install \
      --without-ada \
      --without-cxx-binding \
      --enable-widec \
      --enable-pc-files \
      --with-pkg-config-libdir=/usr/lib/pkgconfig
  make -j"$JOBS"
  make DESTDIR="$WORK/payload" install
)

find "$WORK/payload/usr/lib" -type f \
  \( -name '*.so.*' -o -name '*.a' \) -print0 |
  while IFS= read -r -d '' file; do
    "$STRIP" --strip-unneeded "$file" 2>/dev/null || true
  done

install -d "$SYSROOT/usr/include" "$SYSROOT/usr/lib" "$SYSROOT/usr/share"
cp -a "$WORK/payload/usr/include/." "$SYSROOT/usr/include/"
cp -a "$WORK/payload/usr/lib/." "$SYSROOT/usr/lib/"
[ -d "$WORK/payload/usr/share/terminfo" ] &&
  cp -a "$WORK/payload/usr/share/terminfo" "$SYSROOT/usr/share/"

{
  echo "Source: ncurses"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: shared+normal wide-character terminal libraries cross $TARGET"
  echo "Compiler: $("$CC" --version | head -1)"
} > "$WORK/payload/usr/share/altitude/sources/ncurses.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/ncurses/MANIFEST" "$WORK/payload" \
  "$OUT/altitude-ncurses-$VERSION-amd64.altpkg"
