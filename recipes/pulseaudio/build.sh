#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/pulseaudio}"
VERSION=17.0
TARGET="${ALTITUDE_TARGET_TRIPLET:-x86_64-altitude-linux-gnu}"
TOOLCHAIN_ROOT="${ALTITUDE_TOOLCHAIN_ROOT:-}"
FORGE_ROOT="${ALTITUDE_FORGE_ROOT:-}"
TOOLCHAIN="$TOOLCHAIN_ROOT/opt/altitude/toolchain"
FORGE="$FORGE_ROOT/opt/altitude/forge"
SYSROOT="$TOOLCHAIN/sysroot"
CC="$TOOLCHAIN/bin/$TARGET-gcc"
AR="$TOOLCHAIN/bin/$TARGET-ar"
STRIP="$TOOLCHAIN/bin/$TARGET-strip"
PKG_CONFIG="$FORGE/bin/pkg-config"
PAYLOAD="$WORK/payload"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" pulseaudio)"

export PATH="$FORGE/bin:$TOOLCHAIN/bin:$PATH"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export LDFLAGS="${LDFLAGS:-} -Wl,-rpath-link,$SYSROOT/usr/lib -Wl,-rpath-link,$SYSROOT/usr/lib64 -L$SYSROOT/usr/lib -L$SYSROOT/usr/lib64"

for tool in "$CC" "$AR" "$STRIP" "$PKG_CONFIG" meson ninja; do
  command -v "$tool" >/dev/null || { echo "pulseaudio: missing build tool: $tool" >&2; exit 1; }
done
for dep in alsa glib-2.0 gobject-2.0 gio-2.0 dbus-1 libelogind; do
  "$PKG_CONFIG" --exists "$dep" || { echo "pulseaudio: target dependency missing: $dep" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/build" "$PAYLOAD/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

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
c_link_args = ['-Wl,-rpath-link,$SYSROOT/usr/lib', '-Wl,-rpath-link,$SYSROOT/usr/lib64']
EOF

meson setup "$WORK/build" "$WORK/source" \
  --cross-file="$WORK/cross.ini" --prefix=/usr --libdir=lib \
  --buildtype=release --wrap-mode=nofallback \
  -Dclient=true -Ddaemon=false -Dtests=false -Ddoxygen=false -Dman=false \
  -Ddatabase=simple -Dalsa=enabled -Dglib=enabled -Ddbus=enabled \
  -Delogind=enabled -Dsystemd=disabled -Dudev=disabled \
  -Dasyncns=disabled -Davahi=disabled -Dbluez5=disabled \
  -Dbluez5-gstreamer=disabled -Dconsolekit=disabled -Dfftw=disabled \
  -Dgsettings=disabled -Dgstreamer=disabled -Dgtk=disabled \
  -Djack=disabled -Dlirc=disabled -Dopenssl=disabled -Dorc=disabled \
  -Doss-output=disabled -Dsoxr=disabled -Dspeex=disabled \
  -Dtcpwrap=disabled -Dvalgrind=disabled -Dx11=disabled \
  -Dbashcompletiondir=no -Dzshcompletiondir=no
DESTDIR="$PAYLOAD" meson install -C "$WORK/build"
ln -sf pulseaudio/libpulsecommon-$VERSION.so \
  "$PAYLOAD/usr/lib/libpulsecommon-$VERSION.so"

find "$PAYLOAD/usr/lib" -type f -name '*.so*' -exec "$STRIP" --strip-unneeded {} + 2>/dev/null || true
cp -a "$PAYLOAD/usr/." "$SYSROOT/usr/"

{
  echo "Source: pulseaudio"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: Meson client libraries cross $TARGET"
  echo "Compiler: $("$CC" --version | head -1)"
} > "$PAYLOAD/usr/share/altitude/sources/pulseaudio.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/pulseaudio/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-pulseaudio-$VERSION-amd64.altpkg"
