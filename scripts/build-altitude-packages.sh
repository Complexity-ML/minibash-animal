#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ALTITUDE_PACKAGE_OUT:-$ROOT/out/packages}"
SOURCE_OUT="${ALTITUDE_SOURCE_PACKAGE_OUT:-$ROOT/out/source-packages}"
EXTRA_OUT="${ALTITUDE_EXTRA_PACKAGE_OUT:-$ROOT/out}"
REPO="${ALTITUDE_REPO_ROOT:-$ROOT/out/repository}"
BUILDER="$ROOT/rootfs/bin/altpkg-build"
INCLUDE_SOURCE_PACKAGES="${ALTITUDE_INCLUDE_SOURCE_PACKAGES:-1}"

mkdir -p "$OUT"
rm -f "$OUT"/*.altpkg
mkdir -p "$REPO/packages"
rm -f "$REPO"/INDEX "$REPO"/INDEX.sig "$REPO"/packages/*.altpkg \
  "$REPO"/packages/*.altpkg.sig
for recipe in "$ROOT"/packages/*; do
  [ -d "$recipe" ] || continue
  manifest="$recipe/MANIFEST"
  files="$recipe/FILES"
  name="$(sed -n 's/^Name: *//p' "$manifest")"
  version="$(sed -n 's/^Version: *//p' "$manifest")"
  arch="$(sed -n 's/^Architecture: *//p' "$manifest")"
  stage="$(mktemp -d)"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ -e "$ROOT/rootfs/$path" ] || {
      echo "missing package input: rootfs/$path" >&2
      exit 1
    }
    mkdir -p "$stage/$(dirname "$path")"
    cp -a "$ROOT/rootfs/$path" "$stage/$path"
  done < "$files"
  # Package permissions are part of the artifact contract, independent of the
  # host checkout's executable bits.
  find "$stage/bin" -type f -exec chmod 755 {} + 2>/dev/null || true
  find "$stage/services" -type f -name '*.sh' -exec chmod 755 {} + \
    2>/dev/null || true
  package="$OUT/$name-$version-$arch.altpkg"
  bash "$BUILDER" "$manifest" "$stage" "$package"
  rm -rf "$stage"
done

ALTITUDE_REPO_ROOT="$REPO" bash "$ROOT/rootfs/bin/altrepo" init
if [ ! -f "$REPO/private/repository.pem" ]; then
  ALTITUDE_REPO_ROOT="$REPO" bash "$ROOT/rootfs/bin/altrepo" keygen
fi
for package in "$OUT"/*.altpkg; do
  ALTITUDE_REPO_ROOT="$REPO" bash "$ROOT/rootfs/bin/altrepo" add "$package"
done
if [ "$INCLUDE_SOURCE_PACKAGES" = 1 ] && compgen -G "$SOURCE_OUT/*.altpkg" >/dev/null; then
  for package in "$SOURCE_OUT"/*.altpkg; do
    ALTITUDE_REPO_ROOT="$REPO" bash "$ROOT/rootfs/bin/altrepo" add "$package"
  done
fi
if [ "$INCLUDE_SOURCE_PACKAGES" = 1 ] && compgen -G "$EXTRA_OUT/*.altpkg" >/dev/null; then
  for package in "$EXTRA_OUT"/*.altpkg; do
    ALTITUDE_REPO_ROOT="$REPO" bash "$ROOT/rootfs/bin/altrepo" add "$package"
  done
fi
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$OUT" "$SOURCE_OUT" "$EXTRA_OUT" "$REPO"
fi
ALTITUDE_REPO_ROOT="$REPO" bash "$ROOT/rootfs/bin/altrepo" verify
echo "Altitude repository: $REPO"
