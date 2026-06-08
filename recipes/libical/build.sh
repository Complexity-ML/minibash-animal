#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/libical}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
VERSION=3.0.20
TARGET="${ALTITUDE_TARGET_TRIPLET:-x86_64-altitude-linux-gnu}"
TOOLCHAIN_ROOT="${ALTITUDE_TOOLCHAIN_ROOT:-}"
FORGE_ROOT="${ALTITUDE_FORGE_ROOT:-}"
TOOLCHAIN="$TOOLCHAIN_ROOT/opt/altitude/toolchain"
FORGE="$FORGE_ROOT/opt/altitude/forge"
SYSROOT="$TOOLCHAIN/sysroot"
CC="$TOOLCHAIN/bin/$TARGET-gcc"
CXX="$TOOLCHAIN/bin/$TARGET-g++"
AR="$TOOLCHAIN/bin/$TARGET-ar"
STRIP="$TOOLCHAIN/bin/$TARGET-strip"
PKG_CONFIG="$FORGE/bin/pkg-config"
PAYLOAD="$WORK/payload"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" libical)"

export PATH="$FORGE/bin:$TOOLCHAIN/bin:$PATH"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export LD_LIBRARY_PATH="$SYSROOT/usr/lib:$SYSROOT/usr/lib64:$FORGE/lib:${LD_LIBRARY_PATH:-}"

for tool in "$CC" "$CXX" "$AR" "$STRIP" "$PKG_CONFIG" cmake ninja; do
  command -v "$tool" >/dev/null || { echo "libical: missing build tool: $tool" >&2; exit 1; }
done
for dep in glib-2.0 gobject-2.0; do
  "$PKG_CONFIG" --exists "$dep" || { echo "libical: target dependency missing: $dep" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/build" "$PAYLOAD/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

export CC CXX AR STRIP
export LDFLAGS="${LDFLAGS:-} -Wl,-rpath-link,$SYSROOT/usr/lib -Wl,-rpath-link,$SYSROOT/usr/lib64 -L$SYSROOT/usr/lib -L$SYSROOT/usr/lib64"
cmake -S "$WORK/source" -B "$WORK/build" -G Ninja \
  -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
  -DICAL_BUILD_DOCS=OFF -DICAL_BUILD_EXAMPLES=OFF -DLIBICAL_BUILD_TESTING=OFF \
  -DICAL_GLIB=ON -DGOBJECT_INTROSPECTION=OFF -DICAL_GLIB_VAPI=OFF \
  -DUSE_BUILTIN_TZDATA=ON
cmake --build "$WORK/build" --parallel "$JOBS"
DESTDIR="$PAYLOAD" cmake --install "$WORK/build"

find "$PAYLOAD/usr" -type f -perm -0100 -print0 |
  while IFS= read -r -d '' file; do
    "$STRIP" --strip-unneeded "$file" 2>/dev/null || true
  done
cp -a "$PAYLOAD/usr/." "$SYSROOT/usr/"

{
  echo "Source: libical"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: CMake shared cross $TARGET with libical-glib"
  echo "Compiler: $("$CC" --version | head -1)"
} > "$PAYLOAD/usr/share/altitude/sources/libical.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/libical/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-libical-$VERSION-amd64.altpkg"
