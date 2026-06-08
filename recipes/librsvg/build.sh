#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/librsvg}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
VERSION=2.40.21
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
PKG_CONFIG="$FORGE/bin/pkg-config"
PAYLOAD="$WORK/payload"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" librsvg)"

export PATH="$FORGE/bin:$TOOLCHAIN/bin:$PATH"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"

for tool in "$CC" "$AR" "$RANLIB" "$STRIP" "$PKG_CONFIG" glib-mkenums sed; do
  command -v "$tool" >/dev/null || { echo "librsvg: missing build tool: $tool" >&2; exit 1; }
done
for dep in gdk-pixbuf-2.0 glib-2.0 gio-2.0 libxml-2.0 pangocairo pangoft2 cairo cairo-png libcroco-0.6 gobject-introspection-1.0; do
  "$PKG_CONFIG" --exists "$dep" ||
    { echo "librsvg: target dependency is missing: $dep" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/source" "$PAYLOAD/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1
sed -i 's/rsvg_xml_noerror (void \*data, xmlErrorPtr error)/rsvg_xml_noerror (void *data, const xmlError *error)/' \
  "$WORK/source/rsvg-css.c"

BUILD_TRIPLET="$("$WORK/source/config.guess")"
(
  cd "$WORK/source"
  CC="$CC" AR="$AR" RANLIB="$RANLIB" STRIP="$STRIP" PKG_CONFIG="$PKG_CONFIG" \
    LDFLAGS="-Wl,-rpath-link,$SYSROOT/usr/lib -Wl,-rpath-link,$SYSROOT/usr/lib64" \
    ./configure --build="$BUILD_TRIPLET" --host="$TARGET" \
      --prefix=/usr --libdir=/usr/lib \
      --enable-shared --enable-static \
      --disable-pixbuf-loader --disable-gtk-doc --disable-tools \
      --enable-introspection=yes --enable-vala=no
  for makefile in Makefile; do
    [ -f "$makefile" ] || continue
    sed -i \
      -e "s|$SYSROOT$SYSROOT/../../forge/bin/g-ir-scanner|$FORGE/bin/g-ir-scanner|g" \
      -e "s|$SYSROOT$SYSROOT/../../forge/bin/g-ir-compiler|$FORGE/bin/g-ir-compiler|g" \
      -e "s|$SYSROOT$SYSROOT/usr/bin/g-ir-generate|$FORGE/bin/g-ir-generate|g" \
      -e "s|$SYSROOT$SYSROOT/usr/share/gobject-introspection-1.0/Makefile.introspection|$SYSROOT/usr/share/gobject-introspection-1.0/Makefile.introspection|g" \
      "$makefile"
  done
  make -j"$JOBS"
  make DESTDIR="$PAYLOAD" install
)

find "$PAYLOAD/usr/lib" -name '*.la' -delete
"$STRIP" --strip-unneeded "$PAYLOAD"/usr/lib/librsvg-2.so.* 2>/dev/null || true
cp -a "$PAYLOAD/usr/." "$SYSROOT/usr/"

{
  echo "Source: librsvg"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: Autotools shared and static cross $TARGET, Rust-free 2.40 branch"
  echo "Compiler: $("$CC" --version | head -1)"
} > "$PAYLOAD/usr/share/altitude/sources/librsvg.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/librsvg/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-librsvg-$VERSION-amd64.altpkg"
