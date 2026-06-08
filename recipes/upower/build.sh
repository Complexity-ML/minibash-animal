#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/upower}"
VERSION=1.91.2
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
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" upower)"

export PATH="$FORGE/bin:$TOOLCHAIN/bin:$PATH"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export GETTEXTDATADIRS="$SYSROOT/usr/share/gettext:$FORGE/share/gettext-0.26"

for tool in "$CC" "$AR" "$STRIP" "$READELF" "$PKG_CONFIG"; do
  [ -x "$tool" ] || { echo "upower: missing build tool: $tool" >&2; exit 1; }
done
for tool in meson ninja; do
  command -v "$tool" >/dev/null ||
    { echo "upower: missing host build tool: $tool" >&2; exit 1; }
done
for dep in gio-2.0 gio-unix-2.0 glib-2.0 gudev-1.0 polkit-gobject-1 \
  gobject-introspection-1.0; do
  "$PKG_CONFIG" --exists "$dep" ||
    { echo "upower: target dependency missing: $dep" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/build" "$WORK/tools" \
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
c_link_args = ['-Wl,-rpath-link,$SYSROOT/usr/lib', '-Wl,-rpath-link,$SYSROOT/usr/lib64', '-Wl,-rpath-link,$SYSROOT/lib']
EOF

meson setup "$WORK/build" "$WORK/source" \
  --cross-file="$WORK/cross.ini" \
  --prefix=/usr --libdir=lib --libexecdir=libexec \
  --localstatedir=/var --buildtype=release \
  --default-library=both --wrap-mode=nofallback \
  -Dos_backend=linux -Dpolkit=enabled -Didevice=disabled \
  -Dudevrulesdir=/usr/lib/udev/rules.d \
  -Dudevhwdbdir=/usr/lib/udev/hwdb.d \
  -Dsystemdsystemunitdir=no -Dhistorydir=/var/lib/upower \
  -Dstatedir=/var/lib/upower -Dintrospection=enabled \
  -Dman=false -Dgtk-doc=false -Dinstalled_tests=false \
  -Dzshcompletiondir=no
meson compile -C "$WORK/build"
DESTDIR="$PAYLOAD" meson install -C "$WORK/build"

find "$PAYLOAD/usr" -type f -perm -0100 -print0 |
  while IFS= read -r -d '' file; do
    "$STRIP" --strip-unneeded "$file" 2>/dev/null || true
  done
cp -a "$PAYLOAD/usr/." "$SYSROOT/usr/"

{
  echo "Source: upower"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: Meson Linux daemon and library cross $TARGET"
  echo "Service: /usr/libexec/upowerd"
  echo "Compiler: $("$CC" --version | head -1)"
} > "$PAYLOAD/usr/share/altitude/sources/upower.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/upower/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-upower-$VERSION-amd64.altpkg"
