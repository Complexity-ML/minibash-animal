#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/libgweather}"
VERSION=4.4.4
TARGET="${ALTITUDE_TARGET_TRIPLET:-x86_64-altitude-linux-gnu}"
TOOLCHAIN_ROOT="${ALTITUDE_TOOLCHAIN_ROOT:-}"
FORGE_ROOT="${ALTITUDE_FORGE_ROOT:-}"
TOOLCHAIN="$TOOLCHAIN_ROOT/opt/altitude/toolchain"
FORGE="$FORGE_ROOT/opt/altitude/forge"
SYSROOT="$TOOLCHAIN/sysroot"
CC="$TOOLCHAIN/bin/$TARGET-gcc"
AR="$TOOLCHAIN/bin/$TARGET-ar"
STRIP="$TOOLCHAIN/bin/$TARGET-strip"
READELF="$TOOLCHAIN/bin/$TARGET-readelf"
PKG_CONFIG="$FORGE/bin/pkg-config"
PAYLOAD="$WORK/payload"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" libgweather)"

export PATH="$FORGE/bin:$TOOLCHAIN/bin:$PATH"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"

for tool in "$CC" "$AR" "$STRIP" "$READELF" "$PKG_CONFIG"; do
  [ -x "$tool" ] || { echo "libgweather: missing build tool: $tool" >&2; exit 1; }
done
for tool in meson ninja; do
  command -v "$tool" >/dev/null ||
    { echo "libgweather: missing host build tool: $tool" >&2; exit 1; }
done
for dep in gio-2.0 libsoup-3.0 libxml-2.0 geocode-glib-2.0 json-glib-1.0 \
  gobject-introspection-1.0; do
  "$PKG_CONFIG" --exists "$dep" ||
    { echo "libgweather: target dependency missing: $dep" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/build" "$WORK/tools" \
  "$PAYLOAD/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1
cp "$ROOT/recipes/libgweather/gen_locations_variant_ctypes.py" \
  "$WORK/source/build-aux/meson/gen_locations_variant_ctypes.py"

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

sed -i "s/build_gir = get_option('introspection') and g_ir_scanner.found() and not meson.is_cross_build()/build_gir = get_option('introspection') and g_ir_scanner.found()/" \
  "$WORK/source/meson.build"
sed -i "s/py = import('python').find_installation('python3', modules: \\['gi'\\])/py = import('python').find_installation('python3')/" \
  "$WORK/source/meson.build"
perl -0pi -e "s/subdir\\('data'\\)\\nsubdir\\('schemas'\\)/# Location database generation needs host PyGObject.\\nsubdir('schemas')/" \
  "$WORK/source/meson.build"

cat > "$WORK/cross.ini" <<EOF
[binaries]
c = '$CC'
ar = '$AR'
strip = '$STRIP'
pkg-config = '$PKG_CONFIG'

[properties]
sys_root = '$SYSROOT'
pkg_config_libdir = '$PKG_CONFIG_LIBDIR'
needs_exe_wrapper = true

[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[built-in options]
c_args = ['-O2', '-pipe']
c_link_args = ['-Wl,-rpath-link,$SYSROOT/usr/lib', '-Wl,-rpath-link,$SYSROOT/usr/lib64', '-Wl,-rpath-link,$SYSROOT/lib', '-Wl,-rpath-link,$SYSROOT/lib64']
EOF

meson setup "$WORK/build" "$WORK/source" \
  --cross-file="$WORK/cross.ini" \
  --prefix=/usr --libdir=lib --libexecdir=libexec \
  --buildtype=release --default-library=both --wrap-mode=nofallback \
  -Dsoup2=false -Dintrospection=true -Denable_vala=false \
  -Dgtk_doc=false -Dtests=false
meson compile -C "$WORK/build"
DESTDIR="$PAYLOAD" meson install -C "$WORK/build"

mkdir -p "$PAYLOAD/usr/lib/libgweather-4" "$PAYLOAD/usr/share/libgweather-4"
"$FORGE/bin/python3" "$WORK/source/build-aux/meson/gen_locations_variant_ctypes.py" \
  "$WORK/source/data/Locations.xml" "$PAYLOAD/usr/lib/libgweather-4/Locations.bin"
cp "$WORK/source/data/Locations.xml" "$WORK/source/data/locations.dtd" \
  "$PAYLOAD/usr/share/libgweather-4/"

if command -v glib-compile-schemas >/dev/null 2>&1 &&
   [ -d "$PAYLOAD/usr/share/glib-2.0/schemas" ]; then
  glib-compile-schemas "$PAYLOAD/usr/share/glib-2.0/schemas"
fi
find "$PAYLOAD/usr" -type f -perm -0100 -print0 |
  while IFS= read -r -d '' file; do
    "$STRIP" --strip-unneeded "$file" 2>/dev/null || true
  done
cp -a "$PAYLOAD/usr/." "$SYSROOT/usr/"

{
  echo "Source: libgweather"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: GNOME Weather library and GWeather-4.0 typelib cross $TARGET"
  echo "Compiler: $("$CC" --version | head -1)"
} > "$PAYLOAD/usr/share/altitude/sources/libgweather.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/libgweather/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-libgweather-$VERSION-amd64.altpkg"
