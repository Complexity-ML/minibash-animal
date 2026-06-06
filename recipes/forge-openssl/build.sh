#!/usr/bin/env bash
# Host OpenSSL for the Altitude forge. The kernel's certs/extract-cert (module
# signing / system trusted keyring) links libcrypto and includes <openssl/*.h>,
# which the minimal Omen lacks. Built from locked source into /opt/altitude/forge
# so the kernel keeps module signing -- no Debian -dev packages.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/forge-openssl}"
PREFIX="/opt/altitude/forge"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
COMPILER="${CC:-cc}"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" openssl)"

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/payload/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

( cd "$WORK/source"
  CC="$COMPILER" ./Configure linux-x86_64 \
    --prefix="$PREFIX" --libdir=lib --openssldir="$PREFIX/ssl" \
    shared no-tests no-docs
  make -j"$JOBS"
  # install_sw: libs + headers + pkg-config, skip the (slow) docs/man pages.
  make DESTDIR="$WORK/payload" install_sw
)

find "$WORK/payload$PREFIX" -type f -perm -0100 -exec strip --strip-unneeded {} + \
  2>/dev/null || true

{
  echo "Stage: bootstrap-1"
  echo "Compiler: $("$COMPILER" --version | head -1)"
  echo "openssl-SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
} > "$WORK/payload/usr/share/altitude/sources/forge-openssl.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/forge-openssl/MANIFEST" "$WORK/payload" \
  "$OUT/altitude-forge-openssl-3.3.2-amd64.altpkg"
