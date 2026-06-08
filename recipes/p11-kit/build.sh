#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/p11-kit}"
VERSION=0.25.5
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
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" p11-kit)"

export PATH="$FORGE/bin:$TOOLCHAIN/bin:$PATH"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export LDFLAGS="${LDFLAGS:-} -Wl,-rpath-link,$SYSROOT/usr/lib -Wl,-rpath-link,$SYSROOT/usr/lib64 -L$SYSROOT/usr/lib -L$SYSROOT/usr/lib64"

for tool in "$CC" "$AR" "$STRIP" "$PKG_CONFIG" meson ninja; do
  command -v "$tool" >/dev/null || { echo "p11-kit: missing build tool: $tool" >&2; exit 1; }
done
for dep in libffi; do
  "$PKG_CONFIG" --exists "$dep" || { echo "p11-kit: target dependency missing: $dep" >&2; exit 1; }
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
  -Dtrust_module=disabled -Dsystemd=disabled -Dbash_completion=disabled \
  -Dgtk_doc=false -Dman=false -Dtest=false -Dnls=false \
  -Dsystem_config=/etc/pkcs11 \
  -Dmodule_config=/usr/share/p11-kit/modules \
  -Dmodule_path=/usr/lib/pkcs11
DESTDIR="$PAYLOAD" meson install -C "$WORK/build"

find "$PAYLOAD/usr/lib" -name '*.la' -delete 2>/dev/null || true
"$STRIP" --strip-unneeded "$PAYLOAD"/usr/lib/libp11-kit.so.* 2>/dev/null || true
cp -a "$PAYLOAD/usr/." "$SYSROOT/usr/"

{
  echo "Source: p11-kit"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: Meson shared cross $TARGET, PKCS#11 config paths enabled"
  echo "Compiler: $("$CC" --version | head -1)"
} > "$PAYLOAD/usr/share/altitude/sources/p11-kit.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/p11-kit/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-p11-kit-$VERSION-amd64.altpkg"
