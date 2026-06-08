#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/gjs}"
VERSION=1.84.2
TARGET="${ALTITUDE_TARGET_TRIPLET:-x86_64-altitude-linux-gnu}"
TOOLCHAIN_ROOT="${ALTITUDE_TOOLCHAIN_ROOT:-}"
FORGE_ROOT="${ALTITUDE_FORGE_ROOT:-}"
EXE_WRAPPER="${ALTITUDE_EXE_WRAPPER:-}"
TOOLCHAIN="$TOOLCHAIN_ROOT/opt/altitude/toolchain"
FORGE="$FORGE_ROOT/opt/altitude/forge"
SYSROOT="$TOOLCHAIN/sysroot"
CC="$TOOLCHAIN/bin/$TARGET-gcc"
CXX="$TOOLCHAIN/bin/$TARGET-g++"
AR="$TOOLCHAIN/bin/$TARGET-ar"
STRIP="$TOOLCHAIN/bin/$TARGET-strip"
PKG_CONFIG="$FORGE/bin/pkg-config"
PAYLOAD="$WORK/payload"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" gjs)"
HOST_TOOLS="$WORK/host-tools"

export PATH="$HOST_TOOLS:$FORGE/bin:$TOOLCHAIN/bin:$PATH"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export LD_LIBRARY_PATH="$SYSROOT/usr/lib:$SYSROOT/usr/lib64:$TOOLCHAIN/$TARGET/lib64:$FORGE/lib:${LD_LIBRARY_PATH:-}"

for tool in "$CC" "$CXX" "$AR" "$STRIP" "$PKG_CONFIG"; do
  [ -x "$tool" ] || { echo "gjs: missing build tool: $tool" >&2; exit 1; }
done
for tool in meson ninja python3 g-ir-scanner g-ir-compiler; do
  command -v "$tool" >/dev/null ||
    { echo "gjs: missing forge tool: $tool" >&2; exit 1; }
done
for dep in glib-2.0 gthread-2.0 gobject-2.0 gio-2.0 libffi \
  gobject-introspection-1.0 cairo cairo-gobject mozjs-128; do
  "$PKG_CONFIG" --exists "$dep" ||
    { echo "gjs: target dependency missing from $SYSROOT: $dep" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/build" "$HOST_TOOLS" \
  "$PAYLOAD/usr/share/altitude/sources" "$OUT"
ln -sf "$CC" "$HOST_TOOLS/cc"
ln -sf "$CC" "$HOST_TOOLS/gcc"
ln -sf "$CXX" "$HOST_TOOLS/c++"
ln -sf "$CXX" "$HOST_TOOLS/g++"
ln -sf "$AR" "$HOST_TOOLS/ar"
ln -sf "$AR" "$HOST_TOOLS/gcc-ar"
cat > "$HOST_TOOLS/ldd" <<EOF
#!/usr/bin/env sh
exec "$SYSROOT/usr/lib/ld-linux-x86-64.so.2" --list "\$@"
EOF
chmod 755 "$HOST_TOOLS/ldd"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

if [ -z "$EXE_WRAPPER" ]; then
  EXE_WRAPPER="$WORK/target-wrapper"
  cat > "$EXE_WRAPPER" <<EOF
#!/usr/bin/env sh
export LD_LIBRARY_PATH="$SYSROOT/usr/lib:$SYSROOT/usr/lib64:$SYSROOT/lib:$SYSROOT/lib64:$TOOLCHAIN/$TARGET/lib64:$FORGE/lib:\${LD_LIBRARY_PATH:-}"
exec "\$@"
EOF
  chmod 755 "$EXE_WRAPPER"
fi

cat > "$WORK/cross.ini" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
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
cpp_args = ['-O2', '-pipe']
c_link_args = ['-Wl,-rpath-link,$SYSROOT/usr/lib', '-Wl,-rpath-link,$SYSROOT/usr/lib64', '-Wl,-rpath-link,$TOOLCHAIN/$TARGET/lib64']
cpp_link_args = ['-Wl,-rpath-link,$SYSROOT/usr/lib', '-Wl,-rpath-link,$SYSROOT/usr/lib64', '-Wl,-rpath-link,$TOOLCHAIN/$TARGET/lib64']
EOF

meson setup "$WORK/build" "$WORK/source" \
  --cross-file="$WORK/cross.ini" --prefix=/usr --libdir=lib \
  --buildtype=release --wrap-mode=nofallback \
  -Dreadline=disabled -Dprofiler=disabled \
  -Dinstalled_tests=false -Ddtrace=false -Dsystemtap=false
DESTDIR="$PAYLOAD" meson install -C "$WORK/build"

find "$PAYLOAD/usr" -type f -perm -0100 -print0 |
  while IFS= read -r -d '' file; do
    "$STRIP" --strip-unneeded "$file" 2>/dev/null || true
  done

install -d "$SYSROOT/usr" "$FORGE/bin" "$FORGE/lib"
cp -a "$PAYLOAD/usr/." "$SYSROOT/usr/"
[ -d "$PAYLOAD/usr/bin" ] && cp -a "$PAYLOAD/usr/bin/." "$FORGE/bin/"
[ -d "$PAYLOAD/usr/lib/pkgconfig" ] && cp -a "$PAYLOAD/usr/lib/pkgconfig/." "$SYSROOT/usr/lib/pkgconfig/"

{
  echo "Source: gjs"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: GNOME JavaScript bindings cross $TARGET"
  echo "Compiler: $("$CXX" --version | head -1)"
} > "$PAYLOAD/usr/share/altitude/sources/gjs.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/gjs/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-gjs-$VERSION-amd64.altpkg"
