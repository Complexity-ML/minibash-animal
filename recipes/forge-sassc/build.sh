#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/forge-sassc}"
PREFIX="/opt/altitude/forge"
VERSION=3.6.2
LIBSASS_VERSION=3.6.6
TARGET="${ALTITUDE_TARGET_TRIPLET:-x86_64-altitude-linux-gnu}"
TOOLCHAIN_ROOT="${ALTITUDE_TOOLCHAIN_ROOT:-}"
TOOLCHAIN="$TOOLCHAIN_ROOT/opt/altitude/toolchain"
CC="$TOOLCHAIN/bin/$TARGET-gcc"
CXX="$TOOLCHAIN/bin/$TARGET-g++"
AR="$TOOLCHAIN/bin/$TARGET-ar"
STRIP="$TOOLCHAIN/bin/$TARGET-strip"
SASSC_TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" sassc)"
LIBSASS_TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" libsass)"

export PATH="$PREFIX/bin:$TOOLCHAIN/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/lib:$TOOLCHAIN/$TARGET/lib64:$TOOLCHAIN/sysroot/usr/lib64:$TOOLCHAIN/sysroot/usr/lib:${LD_LIBRARY_PATH:-}"

for tool in "$CC" "$CXX" "$AR" "$STRIP" make; do
  command -v "$tool" >/dev/null ||
    { echo "forge-sassc: missing build tool: $tool" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/libsass" "$WORK/sassc" "$WORK/payload$PREFIX/bin" \
  "$WORK/payload/usr/share/altitude/sources" "$OUT"
tar -xf "$LIBSASS_TARBALL" -C "$WORK/libsass" --strip-components=1
tar -xf "$SASSC_TARBALL" -C "$WORK/sassc" --strip-components=1

(
  cd "$WORK/sassc"
  make -j"${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}" \
    SASS_LIBSASS_PATH="$WORK/libsass" CC="$CC" CXX="$CXX" AR="$AR"
)

install -m 755 "$WORK/sassc/bin/sassc" "$WORK/payload$PREFIX/bin/sassc"
"$STRIP" --strip-unneeded "$WORK/payload$PREFIX/bin/sassc" 2>/dev/null || true

{
  echo "Source: sassc"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$SASSC_TARBALL" | awk '{print $1}')"
  echo "Bundled-Source: libsass"
  echo "Bundled-Version: $LIBSASS_VERSION"
  echo "Bundled-SHA256: $(sha256sum "$LIBSASS_TARBALL" | awk '{print $1}')"
  echo "Build: make SASS_LIBSASS_PATH=libsass"
  echo "Compiler: $("$CC" --version | head -1)"
} > "$WORK/payload/usr/share/altitude/sources/forge-sassc.build"

LD_LIBRARY_PATH="$WORK/payload$PREFIX/lib:$LD_LIBRARY_PATH" \
  "$WORK/payload$PREFIX/bin/sassc" --version >/dev/null

if [ -d "$PREFIX" ]; then
  cp -a "$WORK/payload$PREFIX/." "$PREFIX/"
fi

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/forge-sassc/MANIFEST" "$WORK/payload" \
  "$OUT/altitude-forge-sassc-$VERSION-amd64.altpkg"
