#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/source"/{bin,boot,usr/lib/modules/test,usr/lib/firmware,etc,services}
ln -s usr/lib "$TMP/source/lib"
echo base > "$TMP/source/bin/base"
echo kernel > "$TMP/source/boot/vmlinuz-test"
echo module > "$TMP/source/usr/lib/modules/test/example.ko"
echo firmware > "$TMP/source/usr/lib/firmware/example.bin"
echo identity > "$TMP/source/etc/os-release"
echo debian > "$TMP/source/etc/debian_version"
echo service > "$TMP/source/services/example.sh"
ln -s /proc/mounts "$TMP/source/etc/mtab"

bash "$ROOT/scripts/capture-altitude-system.sh" "$TMP/source" "$TMP/system"
ALTITUDE_PACKAGE_OUT="$TMP/custom" ALTITUDE_REPO_ROOT="$TMP/repository" \
  bash "$ROOT/scripts/build-altitude-packages.sh"
for package in "$TMP/system"/*.altpkg; do
  ALTITUDE_REPO_ROOT="$TMP/repository" \
    bash "$ROOT/rootfs/bin/altrepo" add "$package"
done
ALTITUDE_REPO_ROOT="$TMP/repository" \
  bash "$ROOT/rootfs/bin/altrepo" verify

bash "$ROOT/scripts/assemble-altitude-rootfs.sh" "$TMP/repository" "$TMP/root" \
  altitude-base altitude-kernel altitude-firmware
grep -qx base "$TMP/root/bin/base"
grep -qx kernel "$TMP/root/boot/vmlinuz-test"
grep -qx module "$TMP/root/lib/modules/test/example.ko"
grep -qx firmware "$TMP/root/lib/firmware/example.bin"
[ "$(readlink "$TMP/root/etc/mtab")" = /proc/mounts ]
[ -f "$TMP/root/var/lib/altitude/packages/altitude-base/MANIFEST" ]
[ ! -e "$TMP/root/etc/os-release" ]
[ ! -e "$TMP/root/etc/debian_version" ]
[ ! -e "$TMP/root/services/example.sh" ]

rm -f "$TMP/owned-paths"
for package in "$TMP/repository"/packages/*.altpkg; do
  tar -xOf "$package" ALTITUDE/files.sha256 |
    sed 's/^[^ ]*  //' >> "$TMP/owned-paths"
done
[ -z "$(sort "$TMP/owned-paths" | uniq -d)" ]

bash "$ROOT/scripts/assemble-altitude-rootfs.sh" "$TMP/repository" \
  "$TMP/final-root" altitude-base altitude-kernel altitude-firmware \
  altitude-identity altitude-core altitude-services altitude-access
grep -q '^NAME="Altitude Linux"$' "$TMP/final-root/etc/os-release"
[ -x "$TMP/final-root/bin/pkg" ]
[ -x "$TMP/final-root/services/pkgd.sh" ]
[ -f "$TMP/final-root/root/.ssh/authorized_keys" ]

echo "Altitude signed rootfs assembly: ok"
