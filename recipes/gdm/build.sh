#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/gdm}"
VERSION=48.0
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
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" gdm)"

export PATH="$FORGE/bin:$TOOLCHAIN/bin:$PATH"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"

for tool in "$CC" "$AR" "$STRIP" "$READELF" "$PKG_CONFIG"; do
  [ -x "$tool" ] || { echo "gdm: missing build tool: $tool" >&2; exit 1; }
done
for tool in meson ninja; do
  command -v "$tool" >/dev/null ||
    { echo "gdm: missing host build tool: $tool" >&2; exit 1; }
done
for dep in gio-2.0 gio-unix-2.0 glib-2.0 gobject-2.0 \
  gobject-introspection-1.0 libelogind; do
  "$PKG_CONFIG" --exists "$dep" ||
    { echo "gdm: target dependency missing: $dep" >&2; exit 1; }
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

sed -i \
  -e "s/^udev_dep = dependency('udev')/udev_dep = dependency('udev', required: false)/" \
  -e "s/^gudev_dep = dependency('gudev-1.0'.*/gudev_dep = dependency('gudev-1.0', version: '>= 232', required: false)/" \
  -e "s/^accountsservice_dep = dependency('accountsservice'.*/accountsservice_dep = dependency('accountsservice', version: '>= 0.6.35', required: false)/" \
  "$WORK/source/meson.build"
perl -0pi -e "s/libpam_dep = cc\\.find_library\\('pam'\\)\\npam_extensions_supported = cc\\.has_header_symbol\\(\\n  'security\\/pam_appl\\.h', 'PAM_BINARY_PROMPT',\\n  dependencies: libpam_dep\\)/libpam_dep = dependency('', required: false)\\npam_extensions_supported = false/" \
  "$WORK/source/meson.build"
sed -i "s/^have_pam_syslog = .*/have_pam_syslog = false/" "$WORK/source/meson.build"
perl -0pi -e "s/# Subdirs\\nsubdir\\('data'\\).*?subdir\\('docs'\\)/# Subdirs\\nsubdir('common')\\nsubdir('libgdm')/s" \
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
  -Dlogind-provider=elogind -Dsystemd-journal=false \
  -Dsystemdsystemunitdir=no -Dsystemduserunitdir=no \
  -Dx11-support=false -Dxdmcp=disabled \
  -Dselinux=disabled -Dplymouth=disabled -Dlibaudit=disabled \
  -Ddefault-pam-config=none -Dgdm-xsession=false
meson compile -C "$WORK/build"
DESTDIR="$PAYLOAD" meson install -C "$WORK/build"

install -Dm644 "$WORK/source/data/org.gnome.login-screen.gschema.xml" \
  "$PAYLOAD/usr/share/glib-2.0/schemas/org.gnome.login-screen.gschema.xml"

find "$PAYLOAD/usr" -type f -perm -0100 -print0 |
  while IFS= read -r -d '' file; do
    "$STRIP" --strip-unneeded "$file" 2>/dev/null || true
  done
cp -a "$PAYLOAD/usr/." "$SYSROOT/usr/"

{
  echo "Source: gdm"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: libgdm client library and Gdm-1.0 typelib cross $TARGET"
  echo "Compiler: $("$CC" --version | head -1)"
} > "$PAYLOAD/usr/share/altitude/sources/gdm.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/gdm/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-gdm-$VERSION-amd64.altpkg"
