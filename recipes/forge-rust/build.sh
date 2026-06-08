#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/forge-rust}"
PREFIX="/opt/altitude/forge"
VERSION=1.87.0
TARGET="${ALTITUDE_TARGET_TRIPLET:-x86_64-altitude-linux-gnu}"
TOOLCHAIN_ROOT="${ALTITUDE_TOOLCHAIN_ROOT:-}"
TOOLCHAIN="$TOOLCHAIN_ROOT/opt/altitude/toolchain"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" rust-bin)"

export LD_LIBRARY_PATH="$TOOLCHAIN/$TARGET/lib64:$TOOLCHAIN/sysroot/usr/lib:$TOOLCHAIN/sysroot/usr/lib64:${LD_LIBRARY_PATH:-}"

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/payload$PREFIX" \
  "$WORK/payload/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

(
  cd "$WORK/source"
  ./install.sh \
    --prefix="$PREFIX" \
    --destdir="$WORK/payload" \
    --disable-ldconfig
)

find "$WORK/payload$PREFIX/bin" -type f -perm -0100 \
  -exec strip --strip-unneeded {} + 2>/dev/null || true

{
  echo "Source: rust-bin"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: official Rust bootstrap installed into Altitude forge"
} > "$WORK/payload/usr/share/altitude/sources/forge-rust.build"

LD_LIBRARY_PATH="$WORK/payload$PREFIX/lib:$LD_LIBRARY_PATH" \
  "$WORK/payload$PREFIX/bin/rustc" --version | grep -q "^rustc $VERSION "
LD_LIBRARY_PATH="$WORK/payload$PREFIX/lib:$LD_LIBRARY_PATH" \
  "$WORK/payload$PREFIX/bin/cargo" --version | grep -q "^cargo "

if [ -d "$PREFIX/bin" ]; then
  cp -a "$WORK/payload$PREFIX/." "$PREFIX/"
fi

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/forge-rust/MANIFEST" "$WORK/payload" \
  "$OUT/altitude-forge-rust-$VERSION-amd64.altpkg"
