#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/ca-certificates}"
VERSION=2026.05.14
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" ca-certificates)"
DEST="/etc/ssl/certs/ca-certificates.crt"

rm -rf "$WORK"
mkdir -p "$WORK/payload/etc/ssl/certs" \
  "$WORK/payload/usr/share/altitude/sources" "$OUT"

install -m 644 "$TARBALL" "$WORK/payload$DEST"
ln -sf certs/ca-certificates.crt "$WORK/payload/etc/ssl/cert.pem"

{
  echo "Source: ca-certificates"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: Mozilla CA bundle from curl.se installed for TLS clients"
} > "$WORK/payload/usr/share/altitude/sources/ca-certificates.build"

mkdir -p /etc/ssl/certs
cp -a "$WORK/payload/etc/ssl/." /etc/ssl/

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/ca-certificates/MANIFEST" "$WORK/payload" \
  "$OUT/altitude-ca-certificates-$VERSION-amd64.altpkg"
