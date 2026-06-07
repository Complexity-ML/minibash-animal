#!/usr/bin/env bash
# Build the disk-root artifacts:
#   out/minibash-rootfs.tar.gz  - the full root filesystem, extracted onto the
#                                 target ext4 partition by the installer
#   out/minibash-boot.cpio.gz   - a tiny boot initramfs (busybox + boot-init +
#                                 storage/ext4 modules) that mounts the real
#                                 root and switch_root's into it
#
# Unlike the RAM model, the full rootfs (incl. a desktop later) lives on disk.
set -euo pipefail

DISTRO_DIR="${DISTRO_DIR:-/work/minibash-linux}"
OUT_DIR="${OUT_DIR:-$DISTRO_DIR/out}"
KERNEL_MODULES_DIR="${KERNEL_MODULES_DIR:-$OUT_DIR/debian-modules}"
ROOTFS_TGZ="${ROOTFS_TGZ:-$OUT_DIR/minibash-rootfs.tar.gz}"
BOOT_INITRAMFS="${BOOT_INITRAMFS:-$OUT_DIR/minibash-boot.cpio.gz}"
ROOTFS_WORK="${ROOTFS_WORK:-/tmp/minibash-diskroot}"

log() { printf '[minibash:disk] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Full root filesystem tarball (reuse build.sh to assemble ROOTFS_WORK).
# ---------------------------------------------------------------------------
if [ "${SKIP_ROOTFS:-0}" = "1" ] && [ -f "$ROOTFS_TGZ" ]; then
  log "SKIP_ROOTFS=1: reusing existing $ROOTFS_TGZ"
else
  log "assembling full rootfs via build.sh"
  INCLUDE_DESKTOP="${INCLUDE_DESKTOP:-1}" \
    ROOTFS_WORK="$ROOTFS_WORK" \
    KERNEL_MODULES_DIR="$KERNEL_MODULES_DIR" \
    INITRAMFS_IMG="$OUT_DIR/.diskroot-discard.cpio.gz" \
    bash "$DISTRO_DIR/build.sh" >/dev/null
  rm -f "$OUT_DIR/.diskroot-discard.cpio.gz"

  log "packing rootfs tarball -> $ROOTFS_TGZ"
  tar --numeric-owner --owner=0 --group=0 -czf "$ROOTFS_TGZ" -C "$ROOTFS_WORK" .
fi

# ---------------------------------------------------------------------------
# 2. Tiny boot initramfs: busybox + boot-init + curated storage/fs modules.
# ---------------------------------------------------------------------------
BOOT="/tmp/minibash-boot"
rm -rf "$BOOT"
mkdir -p "$BOOT"/{bin,sbin,proc,sys,dev,newroot,etc}

busybox_bin="$(type -P busybox)"
cp -L "$busybox_bin" "$BOOT/bin/busybox"
chmod +x "$BOOT/bin/busybox"
# applets the stub uses (busybox resolves these from argv[0]); also make the
# modprobe/insmod/switch_root/findfs applets reachable by name.
for ap in sh mount mkdir echo cat sleep modprobe insmod switch_root findfs umount; do
  ln -sf busybox "$BOOT/bin/$ap"
done
# the kernel's request_module() execs /sbin/modprobe (e.g. ext4 pulling crc32c)
ln -sf ../bin/busybox "$BOOT/sbin/modprobe"
ln -sf ../bin/busybox "$BOOT/sbin/insmod"

cp "$DISTRO_DIR/scripts/boot-init.sh" "$BOOT/init"
chmod +x "$BOOT/init"

# Curated storage + filesystem modules (+ their dirs) so modprobe can mount an
# ext4 (or vfat) root off SATA/AHCI/NVMe/USB. depmod builds the dep index.
ver="$(ls "$KERNEL_MODULES_DIR/lib/modules" | head -1)"
log "boot initramfs modules for kernel $ver"
mod_src="$KERNEL_MODULES_DIR/lib/modules/$ver"
mod_dst="$BOOT/lib/modules/$ver"
mkdir -p "$mod_dst"
# copy the kernel module config files depmod needs
for f in modules.builtin modules.builtin.modinfo modules.order; do
  [ -f "$mod_src/$f" ] && cp "$mod_src/$f" "$mod_dst/"
done
for sub in \
  kernel/drivers/ata \
  kernel/drivers/scsi \
  kernel/drivers/nvme \
  kernel/drivers/block/virtio_blk.ko \
  kernel/drivers/scsi/virtio_scsi.ko \
  kernel/drivers/virtio \
  kernel/drivers/usb/core \
  kernel/drivers/usb/host \
  kernel/drivers/usb/storage \
  kernel/fs/ext4 \
  kernel/fs/jbd2 \
  kernel/fs/fat \
  kernel/fs/nls \
  kernel/fs/mbcache.ko \
  kernel/lib/crc16.ko \
  kernel/lib/libcrc32c.ko \
  kernel/crypto/crc32c_generic.ko \
  kernel/arch/x86/crypto/crc32c-intel.ko; do
  source_path=
  for candidate in "$mod_src/$sub" "$mod_src/$sub.xz" \
    "$mod_src/$sub.zst" "$mod_src/$sub.gz"; do
    if [ -e "$candidate" ]; then
      source_path="$candidate"
      break
    fi
  done
  if [ -n "$source_path" ]; then
    mkdir -p "$mod_dst/$(dirname "$sub")"
    cp -a "$source_path" "$mod_dst/$(dirname "$sub")/"
  fi
done
# BusyBox modprobe is intentionally tiny; keep the boot initramfs independent
# from optional module-compression support.
find "$mod_dst" -type f -name '*.ko.xz' -exec xz -d {} +
find "$mod_dst" -type f -name '*.ko.gz' -exec gzip -d {} +
if find "$mod_dst" -type f -name '*.ko.zst' | grep -q .; then
  command -v zstd >/dev/null 2>&1 || {
    echo "zstd is required to unpack kernel modules for the boot initramfs" >&2
    exit 1
  }
  find "$mod_dst" -type f -name '*.ko.zst' -exec zstd -d --rm -q {} +
fi
depmod -b "$BOOT" "$ver"

log "packing boot initramfs -> $BOOT_INITRAMFS"
(cd "$BOOT" && find . -print0 | cpio --null -o -H newc -R 0:0 2>/dev/null | gzip -9 > "$BOOT_INITRAMFS")

log "disk-root artifacts ready:"
ls -lh "$ROOTFS_TGZ" "$BOOT_INITRAMFS"
