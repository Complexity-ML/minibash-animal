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
bash "$ROOT/scripts/build-altitude-firmware-package.sh" "$TMP/source" "$TMP/firmware-only"
tar -tf "$TMP/firmware-only/altitude-firmware-0.1.0-all.altpkg" |
  grep -q '^payload/usr/lib/firmware/example.bin$'
ALTITUDE_PACKAGE_OUT="$TMP/custom" ALTITUDE_REPO_ROOT="$TMP/repository" \
  bash "$ROOT/scripts/build-altitude-packages.sh"
for package in "$TMP/system"/*.altpkg; do
  ALTITUDE_REPO_ROOT="$TMP/repository" \
    bash "$ROOT/rootfs/bin/altrepo" add "$package"
done
ALTITUDE_REPO_ROOT="$TMP/repository" \
  bash "$ROOT/rootfs/bin/altrepo" verify
grep -q '^Package: altitude-desktop-base$' "$TMP/repository/INDEX"

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
  altitude-identity altitude-core altitude-services altitude-access \
  altitude-agentic-shell altitude-dev-tools altitude-desktop-base
grep -q '^NAME="Altitude Linux"$' "$TMP/final-root/etc/os-release"
grep -q '^LANG=C$' "$TMP/final-root/etc/locale.conf"
[ -f "$TMP/final-root/etc/profile" ]
[ -x "$TMP/final-root/bin/pkg" ]
[ -x "$TMP/final-root/bin/alt-agent" ]
[ -x "$TMP/final-root/bin/alt-edit" ]
[ -x "$TMP/final-root/bin/alt-ide" ]
[ -x "$TMP/final-root/bin/altpkg-install" ]
[ -x "$TMP/final-root/bin/altitude-health" ]
[ -x "$TMP/final-root/bin/systemd-bridge" ]
[ -x "$TMP/final-root/bin/movectl" ]
[ -x "$TMP/final-root/bin/movectl-uinput" ]
[ -x "$TMP/final-root/bin/uiopen" ]
[ -x "$TMP/final-root/bin/systemd-audit" ]
[ -f "$TMP/final-root/usr/src/altitude/movectl.c" ]
[ -x "$TMP/final-root/services/pkgd.sh" ]
[ -f "$TMP/final-root/etc/systemd/system/altitude-health.timer" ]
[ "$(readlink "$TMP/final-root/etc/systemd/system/timers.target.wants/altitude-health.timer")" = ../altitude-health.timer ]
grep -q '^Environment=ALTITUDE_HEALTH_REGISTRY=0$' "$TMP/final-root/etc/systemd/system/altitude-health.service"
grep -q '^OnUnitActiveSec=15min$' "$TMP/final-root/etc/systemd/system/altitude-health.timer"
grep -q '^OnBootSec=15min$' "$TMP/final-root/etc/systemd/system/altitude-systemd-audit.timer"
grep -q '^Storage=volatile$' "$TMP/final-root/etc/systemd/journald.conf.d/10-altitude-desktop.conf"
grep -q '^options nouveau atomic=1$' "$TMP/final-root/etc/modprobe.d/nouveau-omen.conf"
[ -f "$TMP/final-root/root/.ssh/authorized_keys" ]
grep -q '^PROFILE=desktop$' "$TMP/final-root/etc/altitude/desktop-base.conf"
grep -q '^polkitd:x:' "$TMP/final-root/etc/group"
grep -q '^polkitd:x:' "$TMP/final-root/etc/passwd"

echo "Altitude signed rootfs assembly: ok"
