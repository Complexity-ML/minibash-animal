#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/grub}"
PREFIX="/opt/altitude/forge"
VERSION=2.12
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
TARGET="${ALTITUDE_TARGET_TRIPLET:-x86_64-altitude-linux-gnu}"
TOOLCHAIN_ROOT="${ALTITUDE_TOOLCHAIN_ROOT:-}"
TOOLCHAIN="$TOOLCHAIN_ROOT/opt/altitude/toolchain"
COMPILER="${CC:-}"
if [ -z "$COMPILER" ]; then
  if command -v cc >/dev/null 2>&1; then
    COMPILER=cc
  elif command -v "$TARGET-gcc" >/dev/null 2>&1; then
    COMPILER="$TARGET-gcc"
  else
    COMPILER="$TOOLCHAIN/bin/$TARGET-gcc"
  fi
fi
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" grub)"
TARGET_CC="${TARGET_CC:-$TOOLCHAIN/bin/$TARGET-gcc}"
TARGET_AR="${TARGET_AR:-$TOOLCHAIN/bin/$TARGET-ar}"
TARGET_OBJCOPY="${TARGET_OBJCOPY:-$TOOLCHAIN/bin/$TARGET-objcopy}"
TARGET_STRIP="${TARGET_STRIP:-$TOOLCHAIN/bin/$TARGET-strip}"
TARGET_NM="${TARGET_NM:-$TOOLCHAIN/bin/$TARGET-nm}"
TARGET_RANLIB="${TARGET_RANLIB:-$TOOLCHAIN/bin/$TARGET-ranlib}"
BUILD_CC="${BUILD_CC:-$COMPILER}"

export PATH="/opt/altitude/forge/bin:$PATH"

for tool in "$BUILD_CC" "$TARGET_CC" "$TARGET_AR" "$TARGET_OBJCOPY" "$TARGET_STRIP" "$TARGET_NM" "$TARGET_RANLIB"; do
  [ -x "$tool" ] || { echo "grub: missing Altitude target tool: $tool" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/build" "$WORK/payload$PREFIX" \
  "$WORK/payload/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1
[ -f "$WORK/source/grub-core/extra_deps.lst" ] ||
  : > "$WORK/source/grub-core/extra_deps.lst"

(
  cd "$WORK/build"
  CC="$COMPILER" \
  AR="$TARGET_AR" \
  RANLIB="$TARGET_RANLIB" \
  NM="$TARGET_NM" \
  STRIP="$TARGET_STRIP" \
  OBJCOPY="$TARGET_OBJCOPY" \
  BUILD_CC="$BUILD_CC" \
  TARGET_CC="$TARGET_CC" \
  TARGET_AR="$TARGET_AR" \
  TARGET_OBJCOPY="$TARGET_OBJCOPY" \
  TARGET_STRIP="$TARGET_STRIP" \
  TARGET_NM="$TARGET_NM" \
  TARGET_RANLIB="$TARGET_RANLIB" \
  ac_cv_header_libdevmapper_h=no \
  "$WORK/source/configure" \
    --prefix="$PREFIX" \
    --target="$TARGET" \
    --with-platform=efi \
    --disable-werror \
    --disable-nls
  make -j"$JOBS"
  make DESTDIR="$WORK/payload" install
)

find "$WORK/payload$PREFIX" -type f -perm -0100 -exec strip --strip-unneeded {} + \
  2>/dev/null || true

{
  echo "Source: grub"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: native GRUB EFI image tools for Altitude boot media"
  echo "Target: $TARGET"
  echo "Platform: x86_64-efi"
  echo "Compiler: $("$COMPILER" --version | head -1)"
  echo "Build-Compiler: $("$BUILD_CC" --version | head -1)"
  echo "Target-Compiler: $("$TARGET_CC" --version | head -1)"
} > "$WORK/payload/usr/share/altitude/sources/grub.build"

if [ -d "$PREFIX" ]; then
  cp -a "$WORK/payload$PREFIX/." "$PREFIX/"
fi

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/grub/MANIFEST" "$WORK/payload" \
  "$OUT/altitude-grub-efi-tools-$VERSION-amd64.altpkg"
