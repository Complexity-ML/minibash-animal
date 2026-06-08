#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/forge-perl}"
PREFIX="/opt/altitude/forge"
VERSION=5.42.2
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
TARGET="${ALTITUDE_TARGET_TRIPLET:-x86_64-altitude-linux-gnu}"
TOOLCHAIN_ROOT="${ALTITUDE_TOOLCHAIN_ROOT:-}"
TOOLCHAIN="$TOOLCHAIN_ROOT/opt/altitude/toolchain"
CC="${CC:-$TOOLCHAIN/bin/$TARGET-gcc}"
AR="${AR:-$TOOLCHAIN/bin/$TARGET-ar}"
RANLIB="${RANLIB:-$TOOLCHAIN/bin/$TARGET-ranlib}"
NM="${NM:-$TOOLCHAIN/bin/$TARGET-nm}"
CPP="${CPP:-$CC -E}"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" perl)"

export PATH="$PREFIX/bin:$TOOLCHAIN/bin:$PATH"

for tool in "$CC" "$AR" "$RANLIB" "$NM"; do
  [ -x "$tool" ] || { echo "forge-perl: missing tool: $tool" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/payload/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

(
  cd "$WORK/source"
  ./Configure -des \
    -Dprefix="$PREFIX" \
    -Dman1dir=none \
    -Dman3dir=none \
    -Dpager=/bin/cat \
    -Dcc="$CC" \
    -Dar="$AR" \
    -Dranlib="$RANLIB" \
    -Dnm="$NM" \
    -Dcpp="$CPP" \
    -Uusethreads
  make -j"$JOBS"
  make DESTDIR="$WORK/payload" install
)

find "$WORK/payload$PREFIX/bin" -type f -perm -0100 -exec strip --strip-unneeded {} + \
  2>/dev/null || true

if [ -d "$PREFIX/bin" ]; then
  cp -a "$WORK/payload$PREFIX/." "$PREFIX/"
fi

{
  echo "Source: perl"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: native forge runtime"
  echo "Compiler: $("$CC" --version | head -1)"
} > "$WORK/payload/usr/share/altitude/sources/forge-perl.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/forge-perl/MANIFEST" "$WORK/payload" \
  "$OUT/altitude-forge-perl-$VERSION-amd64.altpkg"
