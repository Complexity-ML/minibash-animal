#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/mozjs}"
VERSION=128.4.0
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
RANLIB="$TOOLCHAIN/bin/$TARGET-ranlib"
NM="$TOOLCHAIN/bin/$TARGET-nm"
OBJDUMP="$TOOLCHAIN/bin/$TARGET-objdump"
OBJCOPY="$TOOLCHAIN/bin/$TARGET-objcopy"
READELF="$TOOLCHAIN/bin/$TARGET-readelf"
HOST_AR="$AR"
HOST_RANLIB="$RANLIB"
HOST_NM="$NM"
STRIP="$TOOLCHAIN/bin/$TARGET-strip"
PKG_CONFIG="$FORGE/bin/pkg-config"
PAYLOAD="$WORK/payload"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" mozjs)"
HOST_TOOLS="$WORK/host-tools"

export PATH="$HOST_TOOLS:$FORGE/bin:$TOOLCHAIN/bin:$PATH"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export LD_LIBRARY_PATH="$SYSROOT/usr/lib:$SYSROOT/usr/lib64:$TOOLCHAIN/$TARGET/lib64:$FORGE/lib:${LD_LIBRARY_PATH:-}"

for tool in "$CC" "$CXX" "$AR" "$RANLIB" "$NM" "$OBJDUMP" "$OBJCOPY" "$READELF" "$STRIP" "$PKG_CONFIG"; do
  [ -x "$tool" ] || { echo "mozjs: missing build tool: $tool" >&2; exit 1; }
done
for tool in python3 make rustc cargo; do
  command -v "$tool" >/dev/null ||
    { echo "mozjs: missing forge tool: $tool" >&2; exit 1; }
done
for dep in zlib libffi; do
  "$PKG_CONFIG" --exists "$dep" ||
    { echo "mozjs: target dependency missing from $SYSROOT: $dep" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/build" \
  "$HOST_TOOLS" "$PAYLOAD/usr/share/altitude/sources" "$OUT"
ln -sf "$OBJDUMP" "$HOST_TOOLS/objdump"
ln -sf "$STRIP" "$HOST_TOOLS/strip"
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

if [ ! -d "$WORK/source/js/src" ]; then
  echo "mozjs: source tree does not contain js/src" >&2
  exit 1
fi

find "$WORK/source/js/src" -name moz.build -exec \
  perl -0pi -e 's/"\.\.",\s*//g; s/,\s*"\.\."//g' {} +

cat > "$WORK/mozconfig" <<EOF
ac_add_options --host=$TARGET
ac_add_options --target=$TARGET
ac_add_options --prefix=/usr
ac_add_options --libdir=/usr/lib
ac_add_options --disable-debug
ac_add_options --disable-debug-symbols
ac_add_options --disable-jemalloc
ac_add_options --disable-tests
ac_add_options --enable-optimize
ac_add_options --enable-readline=no
ac_add_options --with-system-zlib
ac_add_options --with-intl-api
ac_add_options --without-wasm-sandboxed-libraries
mk_add_options MOZ_OBJDIR=$WORK/build
EOF

(
  cd "$WORK/source/js/src"
  export CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB"
  export NM="$NM" OBJDUMP="$OBJDUMP" OBJCOPY="$OBJCOPY" READELF="$READELF" STRIP="$STRIP"
  export LLVM_OBJDUMP="$OBJDUMP"
  export HOST_AR="$HOST_AR" HOST_RANLIB="$HOST_RANLIB" HOST_NM="$HOST_NM"
  export PKG_CONFIG="$PKG_CONFIG"
  export MOZCONFIG="$WORK/mozconfig"
  export PYTHON3="$FORGE/bin/python3"
  ./configure
  find . -name backend.mk -exec \
    perl -0pi -e "s|(COMPUTED_CXXFLAGS \\+= )|\$1-I$WORK/source/js/src |g; s|(COMPUTED_CFLAGS \\+= )|\$1-I$WORK/source/js/src |g" {} +
  make -C js/src/build -j"${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
  DESTDIR="$PAYLOAD" make -C js/src/build install
)

if [ -d "$PAYLOAD/usr/local" ]; then
  mkdir -p "$PAYLOAD/usr"
  cp -a "$PAYLOAD/usr/local/." "$PAYLOAD/usr/"
  rm -rf "$PAYLOAD/usr/local"
fi
if [ -f "$PAYLOAD/usr/lib/pkgconfig/mozjs-128.pc" ]; then
  perl -0pi -e 's|^prefix=/usr/local$|prefix=/usr|m' "$PAYLOAD/usr/lib/pkgconfig/mozjs-128.pc"
fi

find "$PAYLOAD/usr" -type f -perm -0100 -print0 |
  while IFS= read -r -d '' file; do
    "$STRIP" --strip-unneeded "$file" 2>/dev/null || true
  done

install -d "$SYSROOT/usr"
cp -a "$PAYLOAD/usr/." "$SYSROOT/usr/"

{
  echo "Source: mozjs"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: SpiderMonkey mozjs-128 cross $TARGET"
  echo "Compiler: $("$CXX" --version | head -1)"
  echo "Rust: $(rustc --version)"
} > "$PAYLOAD/usr/share/altitude/sources/mozjs.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/mozjs/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-mozjs-$VERSION-amd64.altpkg"
