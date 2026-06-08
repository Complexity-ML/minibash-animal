#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/bash}"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" bash)"
JOBS="${JOBS:-4}"
TOOLCHAIN=/opt/altitude/toolchain
TARGET=x86_64-altitude-linux-gnu
CC="$TOOLCHAIN/bin/$TARGET-gcc"
AR="$TOOLCHAIN/bin/$TARGET-ar"
RANLIB="$TOOLCHAIN/bin/$TARGET-ranlib"
STRIP="$TOOLCHAIN/bin/$TARGET-strip"
SIZE="$TOOLCHAIN/bin/$TARGET-size"
READELF="$TOOLCHAIN/bin/$TARGET-readelf"
export PATH="$TOOLCHAIN/bin:$PATH"

for tool in "$CC" "$AR" "$RANLIB" "$STRIP" "$SIZE" "$READELF"; do
  [ -x "$tool" ] || {
    echo "bash: Altitude toolchain component missing: $tool" >&2
    exit 1
  }
done

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/build" "$WORK/payload/bin" \
  "$WORK/payload/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

(
  cd "$WORK/build"
  CC="$CC" AR="$AR" RANLIB="$RANLIB" \
  CFLAGS="-O2 -pipe" LDFLAGS="-static" \
    "$WORK/source/configure" \
      --prefix=/usr \
      --bindir=/bin \
      --without-bash-malloc \
      --disable-nls \
      --disable-rpath \
      --enable-static-link
  make -j"$JOBS" SIZE="$SIZE"
)

install -m755 "$WORK/build/bash" "$WORK/payload/bin/bash"
ln -s bash "$WORK/payload/bin/sh"
"$STRIP" --strip-unneeded "$WORK/payload/bin/bash"

{
  echo "Source: bash"
  echo "Version: 5.3"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: static"
  echo "Compiler: $("$CC" --version | head -1)"
} > "$WORK/payload/usr/share/altitude/sources/bash.build"

if command -v ldd >/dev/null 2>&1; then
  ldd_output="$(ldd "$WORK/payload/bin/bash" 2>&1 || true)"
  grep -Eq 'not a dynamic executable|statically linked' <<< "$ldd_output"
else
  ! "$READELF" -l "$WORK/payload/bin/bash" | grep -q 'Requesting program interpreter'
fi
"$WORK/payload/bin/bash" --version | grep -q 'version 5.3'

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/bash/MANIFEST" "$WORK/payload" \
  "$OUT/altitude-bash-5.3-amd64.altpkg"
