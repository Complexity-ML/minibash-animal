#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/at-spi2-core}"
VERSION=2.56.8
TARGET="${ALTITUDE_TARGET_TRIPLET:-x86_64-altitude-linux-gnu}"
TOOLCHAIN_ROOT="${ALTITUDE_TOOLCHAIN_ROOT:-}"
FORGE_ROOT="${ALTITUDE_FORGE_ROOT:-}"
EXE_WRAPPER="${ALTITUDE_EXE_WRAPPER:-}"
TOOLCHAIN="$TOOLCHAIN_ROOT/opt/altitude/toolchain"
FORGE="$FORGE_ROOT/opt/altitude/forge"
SYSROOT="$TOOLCHAIN/sysroot"
CC="$TOOLCHAIN/bin/$TARGET-gcc"
AR="$TOOLCHAIN/bin/$TARGET-ar"
STRIP="$TOOLCHAIN/bin/$TARGET-strip"
PKG_CONFIG="$FORGE/bin/pkg-config"
PAYLOAD="$WORK/payload"
BUILD_TOOLS="$WORK/build-tools"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" at-spi2-core)"

export PATH="$BUILD_TOOLS:$FORGE/bin:$TOOLCHAIN/bin:$PATH"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export LD_LIBRARY_PATH="$SYSROOT/usr/lib:$SYSROOT/usr/lib64:$FORGE/lib:${LD_LIBRARY_PATH:-}"
export LDFLAGS="${LDFLAGS:-} -Wl,-rpath-link,$SYSROOT/usr/lib -Wl,-rpath-link,$SYSROOT/usr/lib64 -L$SYSROOT/usr/lib -L$SYSROOT/usr/lib64"

for tool in "$CC" "$AR" "$STRIP" "$PKG_CONFIG" meson ninja g-ir-scanner g-ir-compiler; do
  command -v "$tool" >/dev/null || { echo "at-spi2-core: missing build tool: $tool" >&2; exit 1; }
done
for dep in glib-2.0 gobject-2.0 gio-2.0 gio-unix-2.0 dbus-1 atk; do
  "$PKG_CONFIG" --exists "$dep" || { echo "at-spi2-core: target dependency missing: $dep" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/build" "$PAYLOAD/usr/share/altitude/sources" "$BUILD_TOOLS" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

cat > "$BUILD_TOOLS/ldd" <<EOF
#!/usr/bin/env sh
exec "$SYSROOT/usr/lib/ld-linux-x86-64.so.2" --list "\$@"
EOF
chmod 755 "$BUILD_TOOLS/ldd"

if [ -z "$EXE_WRAPPER" ]; then
  EXE_WRAPPER="$WORK/target-wrapper"
  cat > "$EXE_WRAPPER" <<EOF
#!/usr/bin/env sh
export LD_LIBRARY_PATH="$SYSROOT/usr/lib:$SYSROOT/usr/lib64:$SYSROOT/lib:$SYSROOT/lib64:$FORGE/lib:\${LD_LIBRARY_PATH:-}"
exec "\$@"
EOF
  chmod 755 "$EXE_WRAPPER"
fi

cat > "$WORK/cross.ini" <<EOF
[binaries]
c = '$CC'
ar = '$AR'
strip = '$STRIP'
pkg-config = '$PKG_CONFIG'
exe_wrapper = '$EXE_WRAPPER'

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
  --cross-file="$WORK/cross.ini" --prefix=/usr --libdir=lib \
  --buildtype=release --default-library=shared --wrap-mode=nofallback \
  -Ddocs=false -Dintrospection=enabled -Dx11=disabled \
  -Dsystemd_user_dir=no
DESTDIR="$PAYLOAD" meson install -C "$WORK/build"

find "$PAYLOAD/usr" -type f -perm -0100 -print0 |
  while IFS= read -r -d '' file; do
    "$STRIP" --strip-unneeded "$file" 2>/dev/null || true
  done
cp -a "$PAYLOAD/usr/." "$SYSROOT/usr/"
{
  echo "Source: at-spi2-core"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: AT-SPI D-Bus bridge without X11/systemd user units, cross $TARGET"
  echo "Compiler: $("$CC" --version | head -1)"
} > "$PAYLOAD/usr/share/altitude/sources/at-spi2-core.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/at-spi2-core/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-at-spi2-core-$VERSION-amd64.altpkg"
