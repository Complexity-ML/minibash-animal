#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/icu}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
VERSION=76.1
TARGET="${ALTITUDE_TARGET_TRIPLET:-x86_64-altitude-linux-gnu}"
TOOLCHAIN_ROOT="${ALTITUDE_TOOLCHAIN_ROOT:-}"
FORGE_ROOT="${ALTITUDE_FORGE_ROOT:-}"
TOOLCHAIN="$TOOLCHAIN_ROOT/opt/altitude/toolchain"
FORGE="$FORGE_ROOT/opt/altitude/forge"
SYSROOT="$TOOLCHAIN/sysroot"
CC="$TOOLCHAIN/bin/$TARGET-gcc"
CXX="$TOOLCHAIN/bin/$TARGET-g++"
AR="$TOOLCHAIN/bin/$TARGET-ar"
RANLIB="$TOOLCHAIN/bin/$TARGET-ranlib"
STRIP="$TOOLCHAIN/bin/$TARGET-strip"
PAYLOAD="$WORK/payload"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" icu)"

export PATH="$FORGE/bin:$TOOLCHAIN/bin:$PATH"
export LD_LIBRARY_PATH="$SYSROOT/usr/lib:$SYSROOT/usr/lib64:$TOOLCHAIN/$TARGET/lib64:$FORGE/lib:${LD_LIBRARY_PATH:-}"

for tool in "$CC" "$CXX" "$AR" "$RANLIB" "$STRIP"; do
  [ -x "$tool" ] || { echo "icu: missing build tool: $tool" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/source" "$PAYLOAD/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

(
  cd "$WORK/source/source"
  CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" \
    CFLAGS="-O2 -pipe" CXXFLAGS="-O2 -pipe" \
    ./configure --prefix=/usr --libdir=/usr/lib \
      --disable-samples --disable-tests --disable-static \
      --enable-shared
  make -j"$JOBS"
  make DESTDIR="$PAYLOAD" install
)

find "$PAYLOAD/usr/lib" -name '*.la' -delete
find "$PAYLOAD/usr" -type f -perm -0100 -print0 |
  while IFS= read -r -d '' file; do
    "$STRIP" --strip-unneeded "$file" 2>/dev/null || true
  done
cp -a "$PAYLOAD/usr/." "$SYSROOT/usr/"

{
  echo "Source: icu"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: native x86_64 Altitude compiler, shared libraries, no samples/tests"
  echo "Compiler: $("$CXX" --version | head -1)"
} > "$PAYLOAD/usr/share/altitude/sources/icu.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/icu/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-icu-$VERSION-amd64.altpkg"
