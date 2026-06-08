#!/usr/bin/env bash
# wpa_supplicant cross-built STATIC by the Altitude toolchain for the native
# slot. nl80211 driver (links the Altitude libnl), internal crypto + internal
# TLS (no OpenSSL needed for WPA2/WPA3-PSK home networks). Static so the binary
# is self-contained on the console-first native root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/wpa-supplicant}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
VERSION=2.11
TARGET=x86_64-altitude-linux-gnu
CROSS="$TARGET-"
TOOLCHAIN=/opt/altitude/toolchain
SYSROOT="$TOOLCHAIN/sysroot"
FORGE=/opt/altitude/forge
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" wpa_supplicant)"

export PATH="$FORGE/bin:$TOOLCHAIN/bin:$PATH"
# Cross pkg-config: resolve the sysroot's libnl and prepend the sysroot to its
# -I/-L (PKG_CONFIG_SYSROOT_DIR) so the Altitude gcc finds the cross libnl.
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig"
export PKG_CONFIG_PATH="$SYSROOT/usr/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/payload/usr/sbin" "$WORK/payload/usr/bin" \
  "$WORK/payload/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

cd "$WORK/source/wpa_supplicant"
cat > .config <<EOF
CONFIG_DRIVER_NL80211=y
CONFIG_LIBNL32=y
CONFIG_CTRL_IFACE=y
CONFIG_CTRL_IFACE_UNIX=y
CONFIG_BACKEND=file
CONFIG_TLS=internal
CONFIG_INTERNAL_LIBTOMMATH=y
EOF

make CC="${CROSS}gcc" -j"$JOBS" wpa_supplicant wpa_cli wpa_passphrase \
  EXTRA_CFLAGS="-O2" LDFLAGS="-static"

install -m755 wpa_supplicant "$WORK/payload/usr/sbin/wpa_supplicant"
install -m755 wpa_cli        "$WORK/payload/usr/bin/wpa_cli"
install -m755 wpa_passphrase "$WORK/payload/usr/bin/wpa_passphrase"

{
  echo "Source: wpa_supplicant"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: static nl80211 internal-crypto cross $TARGET"
  echo "Compiler: $(${CROSS}gcc --version | head -1)"
} > "$WORK/payload/usr/share/altitude/sources/wpa-supplicant.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/wpa-supplicant/MANIFEST" "$WORK/payload" \
  "$OUT/altitude-wpa-supplicant-$VERSION-amd64.altpkg"
