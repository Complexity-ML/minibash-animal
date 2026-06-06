#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/forge-tools}"
PREFIX="/opt/altitude/forge"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
COMPILER="${CC:-cc}"
M4_TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" m4)"
BISON_TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" bison)"
GAWK_TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" gawk)"
FLEX_TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" flex)"
PKGCONF_TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" pkgconf)"

rm -rf "$WORK"
mkdir -p "$WORK/payload$PREFIX" \
  "$WORK/payload/usr/share/altitude/sources" "$OUT"

build_tool() {
  local name="$1" tarball="$2"
  local source="$WORK/$name-source"
  local build="$WORK/$name-build"
  mkdir -p "$source" "$build"
  tar -xf "$tarball" -C "$source" --strip-components=1
  (
    cd "$build"
    "$source/configure" \
      --prefix="$PREFIX" \
      --disable-nls
    make -j"$JOBS"
    make DESTDIR="$WORK/payload" install
  )
}

build_tool m4 "$M4_TARBALL"
export PATH="$WORK/payload$PREFIX/bin:$PATH"
build_tool bison "$BISON_TARBALL"
build_tool gawk "$GAWK_TARBALL"
build_tool flex "$FLEX_TARBALL"   # kernel kconfig/dtc need flex (host tool)
build_tool pkgconf "$PKGCONF_TARBALL"   # provides pkg-config (kernel libelf/libcrypto discovery)
ln -sf pkgconf "$WORK/payload$PREFIX/bin/pkg-config"

find "$WORK/payload$PREFIX" -type f -perm -0100 -exec strip --strip-unneeded {} + \
  2>/dev/null || true

{
  echo "Stage: bootstrap-1"
  echo "Compiler: $("$COMPILER" --version | head -1)"
  for entry in \
    "m4:$M4_TARBALL" \
    "bison:$BISON_TARBALL" \
    "gawk:$GAWK_TARBALL" \
    "flex:$FLEX_TARBALL" \
    "pkgconf:$PKGCONF_TARBALL"; do
    name="${entry%%:*}"
    tarball="${entry#*:}"
    echo "$name-SHA256: $(sha256sum "$tarball" | awk '{print $1}')"
  done
} > "$WORK/payload/usr/share/altitude/sources/forge-tools.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/forge-tools/MANIFEST" "$WORK/payload" \
  "$OUT/altitude-forge-tools-1.0.0-amd64.altpkg"
