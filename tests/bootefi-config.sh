#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

bash -n "$ROOT/scripts/build-live-bootefi.sh"

grep -q 'ALTITUDEEFI' "$ROOT/scripts/build-live-bootefi.sh"
grep -q 'altitude-native' "$ROOT/scripts/build-live-bootefi.sh"
grep -q 'Altitude Linux' "$ROOT/scripts/build-live-bootefi.sh"
! grep -q 'MINIBASHEFI' "$ROOT/scripts/build-live-bootefi.sh"
! grep -q 'root=LABEL=minibashroot' "$ROOT/scripts/build-live-bootefi.sh"
grep -q 'LABEL=altitude-native' "$ROOT/rootfs/etc/fstab"
! grep -q 'LABEL=minibashroot' "$ROOT/rootfs/etc/fstab"

grep -q 'menuentry "Altitude Linux (systemd)"' "$ROOT/build-disk-image.sh"
grep -q 'mformat -i "$esp_img" -F -v ALTITUDEEFI' "$ROOT/build-disk-image.sh"

echo "Altitude EFI boot config: ok"
