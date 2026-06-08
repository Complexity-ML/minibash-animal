#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/dbus}"
VERSION=1.16.2
TARGET="${ALTITUDE_TARGET_TRIPLET:-x86_64-altitude-linux-gnu}"
TOOLCHAIN_ROOT="${ALTITUDE_TOOLCHAIN_ROOT:-}"
FORGE_ROOT="${ALTITUDE_FORGE_ROOT:-}"
TOOLCHAIN="$TOOLCHAIN_ROOT/opt/altitude/toolchain"
SYSROOT="$TOOLCHAIN/sysroot"
FORGE="$FORGE_ROOT/opt/altitude/forge"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
CC="$TOOLCHAIN/bin/$TARGET-gcc"
AR="$TOOLCHAIN/bin/$TARGET-ar"
STRIP="$TOOLCHAIN/bin/$TARGET-strip"
PKG_CONFIG="$FORGE/bin/pkg-config"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" dbus)"

for tool in "$CC" "$AR" "$STRIP" "$PKG_CONFIG"; do
  [ -x "$tool" ] || { echo "dbus: missing build tool: $tool" >&2; exit 1; }
done
export PATH="$FORGE/bin:$TOOLCHAIN/bin:$PATH"
for tool in meson ninja; do
  command -v "$tool" >/dev/null ||
    { echo "dbus: missing host build tool: $tool" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/build" \
  "$WORK/payload/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

cat > "$WORK/cross.ini" <<EOF
[binaries]
c = '$CC'
ar = '$AR'
strip = '$STRIP'
pkg-config = '$PKG_CONFIG'

[properties]
sys_root = '$SYSROOT'
pkg_config_libdir = '$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig'
needs_exe_wrapper = true

[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
"$PKG_CONFIG" --exists expat ||
  { echo "dbus: target Expat is missing from $SYSROOT" >&2; exit 1; }
meson setup "$WORK/build" "$WORK/source" \
  --cross-file="$WORK/cross.ini" \
  --prefix=/usr \
  --libdir=lib \
  --localstatedir=/var \
  --buildtype=release \
  --wrap-mode=nofallback \
  -Ddefault_library=both \
  -Dapparmor=disabled \
  -Dselinux=disabled \
  -Dlibaudit=disabled \
  -Dsystemd=disabled \
  -Dx11_autolaunch=disabled \
  -Dlaunchd=disabled \
  -Dmodular_tests=disabled \
  -Dinstalled_tests=false \
  -Ddoxygen_docs=disabled \
  -Dducktype_docs=disabled \
  -Dxml_docs=disabled \
  -Dqt_help=disabled \
  -Dtools=true \
  -Dmessage_bus=true \
  -Druntime_dir=/run \
  -Dsession_socket_dir=/tmp
DESTDIR="$WORK/payload" ninja -C "$WORK/build" -j"$JOBS" install
chmod 4755 "$WORK/payload/usr/libexec/dbus-daemon-launch-helper" 2>/dev/null || true

find "$WORK/payload/usr" -type f -perm -0100 -print0 |
  while IFS= read -r -d '' file; do
    "$STRIP" --strip-unneeded "$file" 2>/dev/null || true
  done

install -d "$SYSROOT/usr/bin" "$SYSROOT/usr/include" "$SYSROOT/usr/lib" "$FORGE/bin" "$FORGE/lib"
[ -d "$WORK/payload/usr/bin" ] && cp -a "$WORK/payload/usr/bin/." "$SYSROOT/usr/bin/"
[ -d "$WORK/payload/usr/bin" ] && cp -a "$WORK/payload/usr/bin/." "$FORGE/bin/"
cp -a "$WORK/payload/usr/include/." "$SYSROOT/usr/include/"
cp -a "$WORK/payload/usr/lib/." "$SYSROOT/usr/lib/"
cp -a "$WORK/payload/usr/lib/." "$FORGE/lib/"

{
  echo "Source: dbus"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: shared+static cross $TARGET"
  echo "Compiler: $("$CC" --version | head -1)"
  echo "Meson: $(meson --version)"
} > "$WORK/payload/usr/share/altitude/sources/dbus.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/dbus/MANIFEST" "$WORK/payload" \
  "$OUT/altitude-dbus-$VERSION-amd64.altpkg"
