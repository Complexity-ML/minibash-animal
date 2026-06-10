#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/mesa}"
TOOLCHAIN_ROOT="${ALTITUDE_TOOLCHAIN_ROOT:-}"
FORGE_ROOT="${ALTITUDE_FORGE_ROOT:-}"
TARGET="${ALTITUDE_TARGET_TRIPLET:-x86_64-altitude-linux-gnu}"
TOOLCHAIN="$TOOLCHAIN_ROOT/opt/altitude/toolchain"
FORGE="$FORGE_ROOT/opt/altitude/forge"
SYSROOT="$TOOLCHAIN/sysroot"
VERSION=26.1.2
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" mesa)"

export PATH="$FORGE/bin:$TOOLCHAIN/bin:$PATH"
export M4="$FORGE/bin/m4"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
for tool in meson ninja pkg-config python3 "$TARGET-gcc" "$TARGET-g++" wayland-scanner; do
  command -v "$tool" >/dev/null || {
    echo "mesa: missing Altitude forge tool: $tool" >&2
    exit 1
  }
done
python3 -c 'import mako, yaml' >/dev/null 2>&1 || {
  echo "mesa: forge Python modules Mako and PyYAML are required" >&2
  exit 1
}
for dep in libdrm wayland-client wayland-server wayland-protocols; do
  pkg-config --exists "$dep" || {
    echo "mesa: target dependency missing from $SYSROOT: $dep" >&2
    exit 1
  }
done

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/build" \
  "$WORK/payload/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

cat > "$WORK/altitude-cross.ini" <<EOF
[binaries]
c = '$TOOLCHAIN/bin/$TARGET-gcc'
cpp = '$TOOLCHAIN/bin/$TARGET-g++'
ar = '$TOOLCHAIN/bin/$TARGET-ar'
nm = '$TOOLCHAIN/bin/$TARGET-nm'
strip = '$TOOLCHAIN/bin/$TARGET-strip'
pkg-config = '$FORGE/bin/pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[properties]
sys_root = '$SYSROOT'
EOF

BUILD_CC="$(command -v cc || command -v gcc || command -v "$TARGET-gcc")"
BUILD_CXX="$(command -v c++ || command -v g++ || command -v "$TARGET-g++")"
BUILD_AR="$(command -v ar || command -v "$TARGET-ar")"
BUILD_NM="$(command -v nm || command -v "$TARGET-nm")"

cat > "$WORK/altitude-native.ini" <<EOF
[binaries]
c = '$BUILD_CC'
cpp = '$BUILD_CXX'
ar = '$BUILD_AR'
nm = '$BUILD_NM'
EOF

# LLVM, X11 and Vulkan are deliberately outside this bounded graphics layer.
# softpipe provides Mesa's non-LLVM fallback, virgl covers virtio-gpu, and
# nouveau is required on the HP Omen TU116 path so GNOME does not fall back to
# software rendering on the kernel nouveau KMS device.
meson setup "$WORK/build" "$WORK/source" \
  --cross-file="$WORK/altitude-cross.ini" \
  --native-file="$WORK/altitude-native.ini" \
  --prefix=/usr --libdir=lib --buildtype=release \
  -Dplatforms=wayland -Dgallium-drivers=softpipe,virgl,nouveau \
  -Dvulkan-drivers= -Dllvm=disabled -Dshared-llvm=disabled \
  -Dglx=disabled -Degl=enabled -Dgbm=enabled \
  -Dgles1=enabled -Dgles2=enabled -Dopengl=true \
  -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled \
  -Dzstd=disabled -Dbuild-tests=false -Dvideo-codecs=
DESTDIR="$WORK/payload" ninja -C "$WORK/build" install
mkdir -p "$WORK/payload/usr/lib/dri"
for driver in nouveau swrast kms_swrast virtio_gpu; do
  ln -sf ../libgallium-$VERSION.so "$WORK/payload/usr/lib/dri/${driver}_dri.so"
done
cp -a "$WORK/payload/usr/." "$SYSROOT/usr/"

{
  echo "Source: mesa"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: Wayland EGL/GLES/GBM; Gallium softpipe,virgl,nouveau; no LLVM/X11/Vulkan"
  echo "Target: $TARGET"
  echo "Compiler: $("$TARGET-gcc" --version | head -1)"
} > "$WORK/payload/usr/share/altitude/sources/mesa.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/mesa/MANIFEST" "$WORK/payload" \
  "$OUT/altitude-mesa-$VERSION-amd64.altpkg"
