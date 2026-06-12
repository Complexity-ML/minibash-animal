#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/dejavu-fonts}"
VERSION=2.37
TOOLCHAIN_ROOT="${ALTITUDE_TOOLCHAIN_ROOT:-}"
SYSROOT="$TOOLCHAIN_ROOT/opt/altitude/toolchain/sysroot"
PAYLOAD="$WORK/payload"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" dejavu-fonts)"

rm -rf "$WORK"
mkdir -p "$WORK/source" "$PAYLOAD/usr/share/fonts/dejavu" \
  "$PAYLOAD/etc/fonts/conf.d" "$PAYLOAD/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

install -m644 "$WORK/source"/ttf/*.ttf "$PAYLOAD/usr/share/fonts/dejavu/"
install -m644 "$WORK/source"/fontconfig/*.conf "$PAYLOAD/etc/fonts/conf.d/"

if [ -d "$SYSROOT/usr/share" ]; then
  mkdir -p "$SYSROOT/usr/share/fonts/dejavu" "$SYSROOT/etc/fonts/conf.d"
  cp -a "$PAYLOAD/usr/share/fonts/dejavu/." "$SYSROOT/usr/share/fonts/dejavu/"
  cp -a "$PAYLOAD/etc/fonts/conf.d/." "$SYSROOT/etc/fonts/conf.d/"
fi

{
  echo "Source: dejavu-fonts"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: installed TTF fonts and upstream fontconfig aliases"
} > "$PAYLOAD/usr/share/altitude/sources/dejavu-fonts.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/dejavu-fonts/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-dejavu-fonts-$VERSION-all.altpkg"
