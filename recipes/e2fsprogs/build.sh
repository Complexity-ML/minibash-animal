#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/e2fsprogs}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
VERSION=1.47.3
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
PKG_CONFIG="$FORGE/bin/pkg-config"
PAYLOAD="$WORK/payload"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" e2fsprogs)"

export PATH="$FORGE/bin:$TOOLCHAIN/bin:$PATH"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"

for tool in "$CC" "$AR" "$RANLIB" "$STRIP" "$PKG_CONFIG" make; do
  command -v "$tool" >/dev/null || { echo "e2fsprogs: missing build tool: $tool" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/build" "$PAYLOAD/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

BUILD_TRIPLET="$("$WORK/source/config/config.guess")"
(
  cd "$WORK/build"
  CC="$CC" BUILD_CC="$CC" AR="$AR" RANLIB="$RANLIB" PKG_CONFIG="$PKG_CONFIG" \
    CPPFLAGS="-I$SYSROOT/usr/include" \
    LDFLAGS="-L$SYSROOT/usr/lib -Wl,-rpath-link,$SYSROOT/usr/lib" \
    "$WORK/source/configure" \
      --build="$BUILD_TRIPLET" \
      --host="$TARGET" \
      --prefix=/usr \
      --sysconfdir=/etc \
      --sbindir=/usr/sbin \
      --libdir=/usr/lib \
      --enable-elf-shlibs \
      --disable-libuuid \
      --disable-libblkid \
      --disable-fuse2fs \
      --disable-uuidd \
      --disable-nls \
      --without-libarchive \
      --without-pthread \
      --with-udev-rules-dir=/usr/lib/udev/rules.d \
      --with-systemd-unit-dir=/usr/lib/systemd/system
  make -j"$JOBS"
  make DESTDIR="$PAYLOAD" install install-libs
)

find "$PAYLOAD/usr/lib" -name '*.la' -delete 2>/dev/null || true
find "$PAYLOAD/usr/lib" -name '*.a' -delete 2>/dev/null || true
find "$PAYLOAD" -type f -perm -0100 -exec "$STRIP" --strip-unneeded {} + \
  2>/dev/null || true
find "$PAYLOAD/usr/lib" -name '*.so*' -type f -exec "$STRIP" --strip-unneeded {} + \
  2>/dev/null || true

install -d "$SYSROOT/usr"
cp -a "$PAYLOAD/usr/." "$SYSROOT/usr/"

{
  echo "Source: e2fsprogs"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: ext2/ext3/ext4 utilities cross $TARGET"
  echo "Compiler: $("$CC" --version | head -1)"
} > "$PAYLOAD/usr/share/altitude/sources/e2fsprogs.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/e2fsprogs/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-e2fsprogs-$VERSION-amd64.altpkg"
