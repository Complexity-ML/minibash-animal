#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/forge-cbindgen}"
PREFIX="/opt/altitude/forge"
VERSION=0.28.0
TARGET="${ALTITUDE_TARGET_TRIPLET:-x86_64-altitude-linux-gnu}"
TOOLCHAIN_ROOT="${ALTITUDE_TOOLCHAIN_ROOT:-}"
TOOLCHAIN="$TOOLCHAIN_ROOT/opt/altitude/toolchain"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" cbindgen)"

export PATH="$PREFIX/bin:$TOOLCHAIN/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/lib:$TOOLCHAIN/$TARGET/lib64:$TOOLCHAIN/sysroot/usr/lib64:$TOOLCHAIN/sysroot/usr/lib:${LD_LIBRARY_PATH:-}"
export CC="${CC:-$TOOLCHAIN/bin/$TARGET-gcc}"
export CXX="${CXX:-$TOOLCHAIN/bin/$TARGET-g++}"
export AR="${AR:-$TOOLCHAIN/bin/$TARGET-ar}"
export RUSTFLAGS="${RUSTFLAGS:-"-C linker=$CC"}"
export CARGO_HOME="$WORK/cargo-home"
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"
export CARGO_HTTP_CAINFO="${CARGO_HTTP_CAINFO:-$SSL_CERT_FILE}"

[ -x "$PREFIX/bin/cargo" ] || { echo "forge-cbindgen: missing cargo in $PREFIX/bin" >&2; exit 1; }
[ -r "$SSL_CERT_FILE" ] || { echo "forge-cbindgen: missing CA bundle: $SSL_CERT_FILE" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/payload$PREFIX/bin" \
  "$WORK/payload/usr/share/altitude/sources" "$OUT" "$CARGO_HOME"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

(
  cd "$WORK/source"
  cargo build --release --locked
)

install -m 755 "$WORK/source/target/release/cbindgen" "$WORK/payload$PREFIX/bin/cbindgen"
strip --strip-unneeded "$WORK/payload$PREFIX/bin/cbindgen" 2>/dev/null || true

{
  echo "Source: cbindgen"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: cargo build --release --locked"
  echo "Rust: $(rustc --version)"
} > "$WORK/payload/usr/share/altitude/sources/forge-cbindgen.build"

LD_LIBRARY_PATH="$WORK/payload$PREFIX/lib:$LD_LIBRARY_PATH" \
  "$WORK/payload$PREFIX/bin/cbindgen" --version | grep -q "^cbindgen $VERSION$"

if [ -d "$PREFIX/bin" ]; then
  cp -a "$WORK/payload$PREFIX/." "$PREFIX/"
fi

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/forge-cbindgen/MANIFEST" "$WORK/payload" \
  "$OUT/altitude-forge-cbindgen-$VERSION-amd64.altpkg"
