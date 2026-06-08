#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/nss}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
VERSION=3.112.1
TARGET="${ALTITUDE_TARGET_TRIPLET:-x86_64-altitude-linux-gnu}"
TOOLCHAIN_ROOT="${ALTITUDE_TOOLCHAIN_ROOT:-}"
FORGE_ROOT="${ALTITUDE_FORGE_ROOT:-}"
TOOLCHAIN="$TOOLCHAIN_ROOT/opt/altitude/toolchain"
FORGE="$FORGE_ROOT/opt/altitude/forge"
SYSROOT="$TOOLCHAIN/sysroot"
CC="$TOOLCHAIN/bin/$TARGET-gcc"
CXX="$TOOLCHAIN/bin/$TARGET-g++"
AR="$TOOLCHAIN/bin/$TARGET-ar"
RANLIB="$TOOLCHAIN/bin/$TARGET-ranlib"
STRIP="$TOOLCHAIN/bin/$TARGET-strip"
PKG_CONFIG="$FORGE/bin/pkg-config"
PAYLOAD="$WORK/payload"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" nss)"

export PATH="$FORGE/bin:$TOOLCHAIN/bin:$PATH"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export LD_LIBRARY_PATH="$SYSROOT/usr/lib:$SYSROOT/usr/lib64:$FORGE/lib:${LD_LIBRARY_PATH:-}"

for tool in "$CC" "$CXX" "$AR" "$RANLIB" "$STRIP" "$PKG_CONFIG" make; do
  command -v "$tool" >/dev/null || { echo "nss: missing build tool: $tool" >&2; exit 1; }
done
for dep in nspr sqlite3 zlib; do
  "$PKG_CONFIG" --exists "$dep" || { echo "nss: target dependency missing: $dep" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/source" "$PAYLOAD/usr/include/nss" "$PAYLOAD/usr/lib/pkgconfig" \
  "$PAYLOAD/usr/bin" "$PAYLOAD/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1
sed -i 's/unsigned char \*sig,/const unsigned char *sig,/' \
  "$WORK/source/nss/lib/nss/utilwrap.c"

(
  cd "$WORK/source/nss"
  make -j"$JOBS" all latest \
    BUILD_OPT=1 \
    NSDISTMODE=copy \
    USE_64=1 \
    USE_SYSTEM_ZLIB=1 \
    NSS_USE_SYSTEM_SQLITE=1 \
    NSS_ENABLE_WERROR=0 \
    NSS_DISABLE_GTESTS=1 \
    NSPR_INCLUDE_DIR="$SYSROOT/usr/include/nspr" \
    NSPR_LIB_DIR="$SYSROOT/usr/lib" \
    SQLITE_INCLUDE_DIR="$SYSROOT/usr/include" \
    SQLITE_LIB_DIR="$SYSROOT/usr/lib" \
    CC="$CC" CCC="$CXX" CXX="$CXX" AR="$AR cr \$@" RANLIB="$RANLIB" \
    OS_CFLAGS="-fPIC -Wno-implicit-function-declaration -Wno-int-conversion -I$SYSROOT/usr/include -I$SYSROOT/usr/include/nspr" \
    XCFLAGS="-fPIC -Wno-implicit-function-declaration -Wno-int-conversion" \
    LDFLAGS="-Wl,-rpath-link,$SYSROOT/usr/lib -Wl,-rpath-link,$SYSROOT/usr/lib64"
)

DIST_DIR="$(find "$WORK/source/dist" -maxdepth 1 -type d -name 'Linux*OPT*' | head -1)"
[ -n "$DIST_DIR" ] || { echo "nss: build output directory not found" >&2; exit 1; }

cp -a "$WORK/source/dist/public/nss/." "$PAYLOAD/usr/include/nss/"
cp -a "$DIST_DIR/lib/." "$PAYLOAD/usr/lib/"
if [ -d "$DIST_DIR/bin" ]; then
  cp -a "$DIST_DIR/bin/." "$PAYLOAD/usr/bin/"
fi

cat > "$PAYLOAD/usr/lib/pkgconfig/nss.pc" <<EOF
prefix=/usr
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include/nss

Name: NSS
Description: Mozilla Network Security Services
Version: $VERSION
Requires: nspr
Libs: -L\${libdir} -lssl3 -lsmime3 -lnss3 -lnssutil3
Cflags: -I\${includedir}
EOF

find "$PAYLOAD/usr/lib" -name '*.chk' -delete
find "$PAYLOAD/usr/lib" -name '*.a' -delete
find "$PAYLOAD/usr/bin" -type f -perm -0100 -print0 |
  while IFS= read -r -d '' file; do
    "$STRIP" --strip-unneeded "$file" 2>/dev/null || true
  done
find "$PAYLOAD/usr/lib" -type f -name '*.so' -print0 |
  while IFS= read -r -d '' file; do
    "$STRIP" --strip-unneeded "$file" 2>/dev/null || true
  done
cp -a "$PAYLOAD/usr/." "$SYSROOT/usr/"

{
  echo "Source: nss"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: NSS shared libraries with system NSPR, zlib, sqlite for $TARGET"
  echo "Compiler: $("$CC" --version | head -1)"
} > "$PAYLOAD/usr/share/altitude/sources/nss.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/nss/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-nss-$VERSION-amd64.altpkg"
