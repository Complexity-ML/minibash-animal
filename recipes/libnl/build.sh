#!/usr/bin/env bash
# libnl cross-built by the Altitude toolchain (TARGET library, not a host tool).
# Static-only: wpa_supplicant links it statically into a self-contained binary
# for the native slot. Installed into the toolchain sysroot so the Altitude gcc
# discovers it, and packaged as an .altpkg.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/libnl}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
VERSION=3.11.0
TARGET=x86_64-altitude-linux-gnu
CROSS="$TARGET-"
TOOLCHAIN=/opt/altitude/toolchain
SYSROOT="$TOOLCHAIN/sysroot"
FORGE=/opt/altitude/forge
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" libnl)"

# flex/bison (host) for libnl's generated parsers; Altitude cross toolchain for code.
export PATH="$FORGE/bin:$TOOLCHAIN/bin:$PATH"

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/payload/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

( cd "$WORK/source"
  ./configure --host="$TARGET" --prefix=/usr \
    --disable-shared --enable-static --disable-cli \
    CC="${CROSS}gcc" AR="${CROSS}ar" RANLIB="${CROSS}ranlib" \
    CFLAGS="-O2 -g"
  # wpa_supplicant only needs the core + generic-netlink libraries. The route/
  # nf/xfrm libs have unrelated build issues (e.g. netem.c uses NAME_MAX without
  # <limits.h>) and are not required -- build just the two we need.
  make -j"$JOBS" lib/libnl-3.la lib/libnl-genl-3.la
)

# Manual install of only the two static libs + public headers + pkg-config.
P="$WORK/payload/usr"
install -d "$P/lib/pkgconfig" "$P/include/libnl3"
cp "$WORK/source/lib/.libs/libnl-3.a"      "$P/lib/"
cp "$WORK/source/lib/.libs/libnl-genl-3.a" "$P/lib/"
cp -a "$WORK/source/include/netlink"           "$P/include/libnl3/"
cp "$WORK/source/libnl-3.0.pc" "$WORK/source/libnl-genl-3.0.pc" "$P/lib/pkgconfig/"

# Expose to the Altitude sysroot so the wpa_supplicant target build finds it.
cp -a "$P/include/." "$SYSROOT/usr/include/"
cp -a "$P/lib/."     "$SYSROOT/usr/lib/"

{
  echo "Source: libnl"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: static cross $TARGET"
  echo "Compiler: $(${CROSS}gcc --version | head -1)"
} > "$WORK/payload/usr/share/altitude/sources/libnl.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/libnl/MANIFEST" "$WORK/payload" \
  "$OUT/altitude-libnl-$VERSION-amd64.altpkg"
