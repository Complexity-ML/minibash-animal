#!/usr/bin/env bash
set -euo pipefail

OUT="${1:-/work/minibash-linux/out/debian-vmlinuz}"
MODULES_OUT="${2:-$(dirname "$OUT")/debian-modules}"

apt-get update >/dev/null
pkg="$(apt-cache depends linux-image-amd64 | awk '/Depends: linux-image-[0-9]/ { print $2; exit }')"
[ -n "$pkg" ] || {
  echo "could not resolve linux-image-amd64 dependency" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cd "$tmp"
apt-get download "$pkg" >/dev/null
dpkg-deb -x ./*.deb root

kernel="$(find "$tmp/root/boot" -maxdepth 1 -type f -name 'vmlinuz-*' | sort | tail -n 1)"
[ -n "$kernel" ] || {
  echo "downloaded package did not contain a vmlinuz" >&2
  exit 1
}

mkdir -p "$(dirname "$OUT")"
cp "$kernel" "$OUT"
rm -rf "$MODULES_OUT"
mkdir -p "$MODULES_OUT"

version="$(basename "$kernel" | sed 's/^vmlinuz-//')"
module_root="$tmp/root/lib/modules/$version"
if [ -d "$module_root" ]; then
  mkdir -p "$MODULES_OUT/lib/modules/$version"
  for rel in \
    kernel/drivers/scsi/scsi_mod.ko \
    kernel/drivers/scsi/sd_mod.ko \
    kernel/drivers/usb/core/usbcore.ko \
    kernel/drivers/usb/host/xhci-hcd.ko \
    kernel/drivers/usb/host/xhci-pci.ko \
    kernel/drivers/usb/storage/usb-storage.ko \
    kernel/drivers/usb/storage/uas.ko; do
    if [ -f "$module_root/$rel" ]; then
      mkdir -p "$MODULES_OUT/lib/modules/$version/$(dirname "$rel")"
      cp "$module_root/$rel" "$MODULES_OUT/lib/modules/$version/$rel"
    fi
  done
  find "$MODULES_OUT/lib/modules/$version" -type f | sort > "$MODULES_OUT/MODULES"
fi
printf '[minibash:kernel] debian kernel: %s -> %s\n' "$pkg" "$OUT"
printf '[minibash:kernel] debian modules -> %s\n' "$MODULES_OUT"
