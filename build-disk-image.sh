#!/usr/bin/env bash
# Assemble a bootable disk-root image (GPT: EFI System Partition with GRUB +
# kernel plus optional boot initramfs, and an ext4 root partition populated from the rootfs
# tarball). Fully unprivileged: mke2fs -d for the root fs, mtools for the ESP,
# grub-mkstandalone for the bootloader. dd this onto the target SSD/HDD, or boot
# it in QEMU to validate the disk-root boot model.
set -euo pipefail

DISTRO_DIR="${DISTRO_DIR:-$(cd "$(dirname "$0")" && pwd)}"
OUT_DIR="${OUT_DIR:-$DISTRO_DIR/out}"
ROOTFS_TGZ="${ROOTFS_TGZ:-$OUT_DIR/altitude-rootfs.tar.gz}"
BOOT_INITRAMFS="${BOOT_INITRAMFS:-$OUT_DIR/minibash-boot.cpio.gz}"
KERNEL_IMAGE="${KERNEL_IMAGE:-$OUT_DIR/altitude-vmlinuz}"
DISK_IMG="${DISK_IMG:-$OUT_DIR/altitude-linux-disk.img}"
IMG_SIZE_MB="${IMG_SIZE_MB:-5120}"
ESP_MB="${ESP_MB:-256}"
ROOT_LABEL="${ROOT_LABEL:-altitude-native}"

log() { printf '[altitude:diskimg] %s\n' "$*"; }

[ -f "$ROOTFS_TGZ" ] || { echo "missing rootfs tarball: $ROOTFS_TGZ" >&2; exit 1; }

# --- extract rootfs to a staging dir for mke2fs -d --------------------------
ROOTDIR=/tmp/mb-root-extract
rm -rf "$ROOTDIR"; mkdir -p "$ROOTDIR"
log "extracting rootfs tarball"
tar -xzf "$ROOTFS_TGZ" -C "$ROOTDIR"

# --- boot: use the rootfs's own packaged kernel and optional initrd ----------
ver="$(ls "$ROOTDIR/lib/modules" | head -1)"
KERNEL_IMAGE="${KERNEL_IMAGE_OVERRIDE:-$ROOTDIR/boot/vmlinuz-$ver}"
INITRD_IMAGE="${INITRD_IMAGE_OVERRIDE:-$BOOT_INITRAMFS}"
[ -f "$KERNEL_IMAGE" ] || { echo "no kernel /boot/vmlinuz-$ver in rootfs" >&2; exit 1; }
if [ -f "$INITRD_IMAGE" ]; then
  USE_INITRD=1
  log "Altitude kernel $ver + initrd"
else
  USE_INITRD=0
  log "Altitude kernel $ver without initrd"
fi

# --- geometry ---------------------------------------------------------------
esp_sectors=$((ESP_MB * 1024 * 1024 / 512))
data_start=$((2048 + esp_sectors))
data_mb=$((IMG_SIZE_MB - ESP_MB - 2))

log "creating ${IMG_SIZE_MB}MiB image"
rm -f "$DISK_IMG"
dd if=/dev/zero of="$DISK_IMG" bs=1M count="$IMG_SIZE_MB" status=none

sfdisk "$DISK_IMG" >/dev/null <<EOF
label: gpt
unit: sectors
first-lba: 2048
start=2048, size=${ESP_MB}M, type=uefi, name="ALTITUDEEFI"
start=${data_start}, type=linux, name="ALTITUDEROOT"
EOF

# --- ext4 root partition (populated, unprivileged) --------------------------
log "building ext4 root (${data_mb}MiB) from rootfs"
data_img="$(mktemp)"
mke2fs -q -t ext4 -L "$ROOT_LABEL" -d "$ROOTDIR" -F "$data_img" "${data_mb}M"

# --- ESP: GRUB + kernel + optional boot initramfs ---------------------------
log "building ESP (GRUB + kernel)"
esp_img="$(mktemp)"
dd if=/dev/zero of="$esp_img" bs=1M count="$ESP_MB" status=none
mformat -i "$esp_img" -F -v ALTITUDEEFI ::
mmd -i "$esp_img" ::/EFI ::/EFI/BOOT

grub_cfg="$(mktemp)"
trap 'rm -f "$grub_cfg" "$esp_img" "$data_img"' EXIT
cat > "$grub_cfg" <<CFG
set timeout=3
set default=0
serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_input console serial
terminal_output console serial
search --no-floppy --label ALTITUDEEFI --set=root

menuentry "Altitude Linux (systemd)" {
  search --no-floppy --label ALTITUDEEFI --set=root
  linux /kernel root=LABEL=${ROOT_LABEL} rootfstype=ext4 rw fsck.repair=yes init=/init altitude.init=systemd systemd.unit=graphical.target minibash.root=disk iwlmvm.power_scheme=1 console=ttyS0,115200 console=tty0 panic=0 loglevel=4 minibash.tty=tty1 minibash.autologin=root minibash.keymap=fr
}

menuentry "Altitude Linux (systemd serial)" {
  search --no-floppy --label ALTITUDEEFI --set=root
  linux /kernel root=LABEL=${ROOT_LABEL} rootfstype=ext4 rw fsck.repair=yes init=/init altitude.init=systemd systemd.unit=multi-user.target minibash.root=disk iwlmvm.power_scheme=1 console=ttyS0,115200 panic=0 loglevel=7 minibash.tty=ttyS0 minibash.autologin=root minibash.keymap=fr
}

menuentry "Altitude Linux (BusyBox fallback)" {
  search --no-floppy --label ALTITUDEEFI --set=root
  linux /kernel root=LABEL=${ROOT_LABEL} rootfstype=ext4 rw fsck.repair=yes init=/init altitude.init=busybox minibash.root=disk iwlmvm.power_scheme=1 console=ttyS0,115200 console=tty0 panic=0 loglevel=4 minibash.tty=tty1 minibash.autologin=root minibash.keymap=fr
}
CFG

if [ "$USE_INITRD" = 1 ]; then
  sed -i '/^  linux /a\  initrd /initrd.img' "$grub_cfg"
fi

bootefi="$(mktemp)"
grub-mkstandalone \
  -O x86_64-efi \
  --modules="part_gpt fat ext2 search search_label linux normal configfile efi_gop efi_uga all_video serial terminal" \
  -o "$bootefi" \
  "boot/grub/grub.cfg=$grub_cfg" >/dev/null
mcopy -i "$esp_img" "$bootefi" ::/EFI/BOOT/BOOTX64.EFI
rm -f "$bootefi"
mcopy -i "$esp_img" "$KERNEL_IMAGE" ::/kernel
if [ "$USE_INITRD" = 1 ]; then
  mcopy -i "$esp_img" "$INITRD_IMAGE" ::/initrd.img
fi

# --- assemble ---------------------------------------------------------------
log "writing partitions into image"
dd if="$esp_img" of="$DISK_IMG" bs=512 seek=2048 conv=notrunc status=none
dd if="$data_img" of="$DISK_IMG" bs=512 seek="$data_start" conv=notrunc status=none

log "disk image ready: $DISK_IMG"
ls -lh "$DISK_IMG"
