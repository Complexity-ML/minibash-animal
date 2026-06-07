#!/usr/bin/env bash
# Host libelf (from elfutils) + zlib for the Altitude forge. The kernel's
# objtool links libelf (gelf.h), which the minimal Omen lacks. We build them
# from locked sources into /opt/altitude/forge so objtool builds and the kernel
# stays full (ORC unwinder + mitigations), with no Debian -dev packages.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/forge-libelf}"
PREFIX="/opt/altitude/forge"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
COMPILER="${CC:-cc}"
ZLIB_TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" zlib)"
ELFUTILS_TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" elfutils)"

rm -rf "$WORK"
mkdir -p "$WORK/payload$PREFIX" "$WORK/payload/usr/share/altitude/sources" "$OUT"
DEST="$WORK/payload"

# --- zlib (libelf needs it for compressed sections) ------------------------
mkdir -p "$WORK/zlib"
tar -xf "$ZLIB_TARBALL" -C "$WORK/zlib" --strip-components=1
( cd "$WORK/zlib"
  CC="$COMPILER" ./configure --prefix="$PREFIX"
  make -j"$JOBS"
  make DESTDIR="$DEST" install
)

# --- elfutils: libelf only (gelf.h, libelf.h, libelf.{a,so}, libelf.pc) -----
mkdir -p "$WORK/elfutils"
tar -xf "$ELFUTILS_TARBALL" -C "$WORK/elfutils" --strip-components=1
( cd "$WORK/elfutils"
  CC="$COMPILER" \
  CFLAGS="-O2 -g -Wno-error -I$DEST$PREFIX/include" \
  LDFLAGS="-L$DEST$PREFIX/lib -Wl,-rpath,$PREFIX/lib" \
  ./configure --prefix="$PREFIX" \
    --disable-debuginfod --disable-libdebuginfod \
    --without-zstd --without-bzlib --without-lzma --disable-nls
  # libelf depends on the helper lib/ (libeu); build both, install only libelf.
  make -C lib -j"$JOBS"
  make -C libelf -j"$JOBS"
  make -C libelf DESTDIR="$DEST" install
)

find "$DEST$PREFIX" -type f -perm -0100 -exec strip --strip-unneeded {} + 2>/dev/null || true

{
  echo "Stage: bootstrap-1"
  echo "Compiler: $("$COMPILER" --version | head -1)"
  echo "zlib-SHA256: $(sha256sum "$ZLIB_TARBALL" | awk '{print $1}')"
  echo "elfutils-SHA256: $(sha256sum "$ELFUTILS_TARBALL" | awk '{print $1}')"
} > "$DEST/usr/share/altitude/sources/forge-libelf.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/forge-libelf/MANIFEST" "$DEST" \
  "$OUT/altitude-forge-libelf-0.192-amd64.altpkg"
