#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/rtkit}"
VERSION=0.13
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
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" rtkit)"

export PATH="$FORGE/bin:$TOOLCHAIN/bin:$PATH"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export LDFLAGS="${LDFLAGS:-} -Wl,-rpath-link,$SYSROOT/usr/lib -Wl,-rpath-link,$SYSROOT/usr/lib64"

for tool in "$CC" "$AR" "$STRIP" "$PKG_CONFIG" meson ninja xxd; do
  command -v "$tool" >/dev/null || { echo "rtkit: missing build tool: $tool" >&2; exit 1; }
done
for dep in dbus-1 libcap; do
  "$PKG_CONFIG" --exists "$dep" ||
    { echo "rtkit: target dependency missing: $dep" >&2; exit 1; }
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
c_args = ['-O2', '-pipe']
c_link_args = ['-Wl,-rpath-link,$SYSROOT/usr/lib', '-Wl,-rpath-link,$SYSROOT/usr/lib64']
EOF

meson setup "$WORK/build" "$WORK/source" \
  --cross-file="$WORK/cross.ini" \
  --prefix=/usr --libdir=lib --libexecdir=libexec \
  --buildtype=release --default-library=both --wrap-mode=nofallback \
  -Dlibsystemd=disabled -Dinstalled_tests=false \
  -Ddbus_systemservicedir=/usr/share/dbus-1/system-services \
  -Ddbus_interfacedir=/usr/share/dbus-1/interfaces \
  -Ddbus_rulesdir=/usr/share/dbus-1/system.d \
  -Dpolkit_actiondir=/usr/share/polkit-1/actions \
  -Dsystemd_systemunitdir=/usr/lib/systemd/system
meson compile -C "$WORK/build"
DESTDIR="$PAYLOAD" meson install -C "$WORK/build"
if [ -d "$PAYLOAD$SYSROOT/usr/lib/systemd/system" ]; then
  install -d "$PAYLOAD/usr/lib/systemd/system"
  cp -a "$PAYLOAD$SYSROOT/usr/lib/systemd/system/." "$PAYLOAD/usr/lib/systemd/system/"
  rm -rf "$PAYLOAD/opt"
fi
if [ -f "$PAYLOAD/usr/share/dbus-1/system-services/org.freedesktop.RealtimeKit1.service" ]; then
  sed -i 's|^Exec=.*|Exec=/usr/libexec/rtkit-daemon --no-canary --no-drop-privileges --no-chroot|' \
    "$PAYLOAD/usr/share/dbus-1/system-services/org.freedesktop.RealtimeKit1.service"
fi
if [ -f "$PAYLOAD/usr/lib/systemd/system/rtkit-daemon.service" ]; then
  sed -i 's|^ExecStart=.*|ExecStart=/usr/libexec/rtkit-daemon --no-canary --no-drop-privileges --no-chroot|' \
    "$PAYLOAD/usr/lib/systemd/system/rtkit-daemon.service"
fi

find "$PAYLOAD/usr" -type f -perm -0100 -print0 |
  while IFS= read -r -d '' file; do
    "$STRIP" --strip-unneeded "$file" 2>/dev/null || true
  done
install -d "$SYSROOT/usr"
cp -a "$PAYLOAD/usr/." "$SYSROOT/usr/"

{
  echo "Source: rtkit"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: Meson RealtimeKit daemon without libsystemd cross $TARGET"
  echo "Service: /usr/libexec/rtkit-daemon"
  echo "Compiler: $("$CC" --version | head -1)"
} > "$PAYLOAD/usr/share/altitude/sources/rtkit.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/rtkit/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-rtkit-$VERSION-amd64.altpkg"
