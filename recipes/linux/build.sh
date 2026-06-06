#!/usr/bin/env bash
# Build the Linux kernel from locked source with the ALTITUDE toolchain -- the
# last piece of Debian provenance in the boot chain. The kernel objects are
# compiled by x86_64-altitude-linux-gnu-gcc (CROSS_COMPILE); host build tools
# come from the Altitude forge (m4/bison/gawk/flex) and BusyBox (bc). HOSTCC is
# the host cc only for throwaway build-time helpers that never ship.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/linux}"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" linux)"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
VERSION=7.0.10
CROSS=x86_64-altitude-linux-gnu-
FORGE=/opt/altitude/forge
TOOLCHAIN=/opt/altitude/toolchain

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/bin" "$WORK/payload/boot" \
  "$WORK/payload/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

# `bc` (kernel timeconst) from the Altitude BusyBox; invoked via a name=bc symlink.
BB="${ALTITUDE_BUSYBOX:-$FORGE/bin/busybox}"
[ -x "$BB" ] || BB=/var/tmp/altitude-forge/work/busybox/source/busybox
[ -x "$BB" ] || BB="$(command -v busybox || true)"
[ -n "$BB" ] && [ -x "$BB" ] || { echo "no busybox for bc" >&2; exit 1; }
ln -sf "$BB" "$WORK/bin/bc"
export PATH="$WORK/bin:$FORGE/bin:$TOOLCHAIN/bin:$PATH"

# objtool (host tool) links libelf from the forge. Make pkg-config + the host
# compiler/linker find it, and the resulting host binary find libelf.so.1 at
# runtime. elfutils may not ship a libelf.pc, so synthesize one.
if [ ! -f "$FORGE/lib/pkgconfig/libelf.pc" ]; then
  mkdir -p "$FORGE/lib/pkgconfig"
  cat > "$FORGE/lib/pkgconfig/libelf.pc" <<PC
prefix=$FORGE
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: libelf
Description: elfutils libelf (Altitude forge)
Version: 0.192
Libs: -L\${libdir} -lelf
Cflags: -I\${includedir}
PC
fi
# The kernel discovers libelf (objtool) / libcrypto (extract-cert) through its
# native pkg-config calls -- no global -I pollution (which would break the other
# host tools, e.g. relocs/mdp finding their own headers). pkgconf lives in the
# forge prefix, so it treats the forge's own include/lib as "system" and strips
# the -I/-L; point its system paths at /usr so it emits the forge flags instead.
# LD_LIBRARY_PATH lets the resulting host tools load libelf.so.1 / libcrypto.so.3.
export PKG_CONFIG_PATH="$FORGE/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export PKG_CONFIG_SYSTEM_INCLUDE_PATH=/usr/include
export PKG_CONFIG_SYSTEM_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:/usr/lib
export LD_LIBRARY_PATH="$FORGE/lib:${LD_LIBRARY_PATH:-}"

kmake() { make -C "$WORK/source" ARCH=x86_64 CROSS_COMPILE="$CROSS" HOSTCC=cc "$@"; }

# FULL kernel, no shortcuts: libelf (objtool) + openssl (module signing /
# extract-cert) live in the forge and the env above points the host build at
# them, so ORC unwinder, IBT, mitigations and MODULE_SIG all stay enabled.
kmake defconfig
kmake olddefconfig
kmake -j"$JOBS" bzImage

install -m644 "$WORK/source/arch/x86/boot/bzImage" \
  "$WORK/payload/boot/vmlinuz-altitude-$VERSION"
install -m644 "$WORK/source/.config" \
  "$WORK/payload/boot/config-altitude-$VERSION"

{
  echo "Source: linux"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: bzImage ARCH=x86_64 CROSS_COMPILE=$CROSS"
  echo "Compiler: $(${CROSS}gcc --version | head -1)"
  echo "Linker: $(${CROSS}ld --version | head -1)"
} > "$WORK/payload/usr/share/altitude/sources/linux.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/linux/MANIFEST" "$WORK/payload" \
  "$OUT/altitude-linux-$VERSION-amd64.altpkg"
