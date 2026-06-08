#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/ibus}"
VERSION=1.5.31
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
NM="$TOOLCHAIN/bin/$TARGET-nm"
OBJDUMP="$TOOLCHAIN/bin/$TARGET-objdump"
READELF="$TOOLCHAIN/bin/$TARGET-readelf"
PKG_CONFIG="$FORGE/bin/pkg-config"
MAKE="$FORGE/bin/make"
PAYLOAD="$WORK/payload"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" ibus)"

export PATH="$FORGE/bin:$TOOLCHAIN/bin:$PATH"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export CPPFLAGS="-I$SYSROOT/usr/include ${CPPFLAGS:-}"
export LDFLAGS="-Wl,-rpath-link,$SYSROOT/usr/lib -Wl,-rpath-link,$SYSROOT/usr/lib64 -L$SYSROOT/usr/lib -L$SYSROOT/usr/lib64 ${LDFLAGS:-}"

for tool in "$CC" "$AR" "$RANLIB" "$STRIP" "$NM" "$OBJDUMP" "$READELF" "$PKG_CONFIG" "$MAKE"; do
  [ -x "$tool" ] || { echo "ibus: missing build tool: $tool" >&2; exit 1; }
done
for dep in glib-2.0 gobject-2.0 gio-2.0 gio-unix-2.0 gthread-2.0 \
  dbus-1 gobject-introspection-1.0 iso-codes xkeyboard-config; do
  "$PKG_CONFIG" --exists "$dep" ||
    { echo "ibus: target dependency missing: $dep" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/tools" \
  "$PAYLOAD/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

cat > "$WORK/tools/ldd" <<EOF
#!/bin/sh
"$READELF" -d "\$1" 2>/dev/null | awk '
  /NEEDED/ {
    lib = \$0
    sub(/^.*\\[/, "", lib)
    sub(/\\].*$/, "", lib)
    print "\\t" lib " => " lib " (0x00000000)"
  }
'
EOF
chmod +x "$WORK/tools/ldd"
export PATH="$WORK/tools:$PATH"

(
  cd "$WORK/source"
  CC="$CC" CC_FOR_BUILD="$CC" AR="$AR" RANLIB="$RANLIB" STRIP="$STRIP" \
  NM="$NM" OBJDUMP="$OBJDUMP" \
  PKG_CONFIG="$PKG_CONFIG" \
  ./configure \
    --prefix=/usr --sysconfdir=/etc --libdir=/usr/lib --libexecdir=/usr/libexec \
    --disable-static --enable-shared --disable-dependency-tracking \
    --disable-tests --disable-gtk2 --disable-gtk3 --disable-gtk4 \
    --disable-xim --disable-wayland --disable-appindicator \
    --enable-introspection=yes --enable-vala=no --disable-gtk-doc \
    --disable-dconf --disable-systemd-services \
    --disable-python2 --disable-python-library --disable-setup \
    --disable-dbus-python-check --disable-ui --disable-engine \
    --disable-libnotify --disable-emoji-dict --disable-unicode-dict \
    --disable-schemas-compile
  for makefile in Makefile src/Makefile; do
    [ -f "$makefile" ] || continue
    sed -i \
      -e "s|$SYSROOT$SYSROOT/../../forge/bin/g-ir-scanner|$FORGE/bin/g-ir-scanner|g" \
      -e "s|$SYSROOT$SYSROOT/../../forge/bin/g-ir-compiler|$FORGE/bin/g-ir-compiler|g" \
      -e "s|$SYSROOT$SYSROOT/usr/bin/g-ir-generate|$FORGE/bin/g-ir-generate|g" \
      -e "s|$SYSROOT$SYSROOT/usr/share/gobject-introspection-1.0/Makefile.introspection|$SYSROOT/usr/share/gobject-introspection-1.0/Makefile.introspection|g" \
      "$makefile"
  done
  "$MAKE"
  DESTDIR="$PAYLOAD" "$MAKE" install
)

if [ -d "$PAYLOAD/usr/lib/girepository-1.0" ]; then
  find "$PAYLOAD/usr/lib/girepository-1.0" -type f -name '*.typelib' -print >/dev/null
fi
find "$PAYLOAD/usr" -type f -perm -0100 -print0 |
  while IFS= read -r -d '' file; do
    "$STRIP" --strip-unneeded "$file" 2>/dev/null || true
  done
cp -a "$PAYLOAD/usr/." "$SYSROOT/usr/"

{
  echo "Source: ibus"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: libibus and IBus-1.0 typelib cross $TARGET"
  echo "Compiler: $("$CC" --version | head -1)"
} > "$PAYLOAD/usr/share/altitude/sources/ibus.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/ibus/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-ibus-$VERSION-amd64.altpkg"
