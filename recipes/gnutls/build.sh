#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/gnutls}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
VERSION=3.8.13
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
PKG_CONFIG="$FORGE/bin/pkg-config"
PAYLOAD="$WORK/payload"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" gnutls)"

export PATH="$FORGE/bin:$TOOLCHAIN/bin:$PATH"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export CPPFLAGS="${CPPFLAGS:-} -I$SYSROOT/usr/include"
export LDFLAGS="${LDFLAGS:-} -L$SYSROOT/usr/lib -Wl,-rpath-link,$SYSROOT/usr/lib"
export LD_LIBRARY_PATH="$SYSROOT/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

for tool in "$CC" "$AR" "$RANLIB" "$STRIP" "$MAKE" "$PKG_CONFIG"; do
  [ -x "$tool" ] || { echo "gnutls: missing build tool: $tool" >&2; exit 1; }
done
for dep in nettle hogweed gmp libtasn1; do
  "$PKG_CONFIG" --exists "$dep" ||
    { echo "gnutls: target dependency missing from $SYSROOT: $dep" >&2; exit 1; }
done
[ -f "$SYSROOT/usr/include/unistr.h" ] ||
  { echo "gnutls: target dependency missing from $SYSROOT: libunistring headers" >&2; exit 1; }
[ -e "$SYSROOT/usr/lib/libunistring.so" ] ||
  { echo "gnutls: target dependency missing from $SYSROOT: libunistring library" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK/source" "$PAYLOAD/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

(
  cd "$WORK/source"
  CC="$CC" AR="$AR" RANLIB="$RANLIB" PKG_CONFIG="$PKG_CONFIG" \
    ./configure --host="$TARGET" --prefix=/usr --libdir=/usr/lib \
      --enable-shared --disable-static --disable-doc --disable-tests \
      --disable-tools --disable-cxx \
      --disable-openssl-compatibility --without-p11-kit \
      --with-system-priority-file=/etc/gnutls/default-priorities
  "$MAKE" -j"$JOBS"
  "$MAKE" DESTDIR="$PAYLOAD" install
)

find "$PAYLOAD/usr/lib" -name '*.la' -delete 2>/dev/null || true
find "$PAYLOAD/usr/lib" -type f -name '*.so*' -exec "$STRIP" --strip-unneeded {} + 2>/dev/null || true
install -d "$SYSROOT/usr"
cp -a "$PAYLOAD/usr/." "$SYSROOT/usr/"

{
  echo "Source: gnutls"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: Autoconf shared cross $TARGET, p11-kit disabled"
  echo "Compiler: $("$CC" --version | head -1)"
} > "$PAYLOAD/usr/share/altitude/sources/gnutls.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/gnutls/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-gnutls-$VERSION-amd64.altpkg"
