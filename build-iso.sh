#!/usr/bin/env bash
set -euo pipefail

DISTRO_DIR="${DISTRO_DIR:-/work/minibash-linux}"
OUT_DIR="${OUT_DIR:-$DISTRO_DIR/out}"
ISO_ROOT="${ISO_ROOT:-/tmp/minibash-linux-iso}"
EFI_IMG="${EFI_IMG:-/tmp/minibash-linux-efiboot.img}"
ISO_NAME="${ISO_NAME:-minibash-linux.iso}"
ISO="$OUT_DIR/$ISO_NAME"
KERNEL_IMAGE="${KERNEL_IMAGE:-$OUT_DIR/bzImage}"
INITRAMFS_IMAGE="${INITRAMFS_IMAGE:-$OUT_DIR/minibash-linux-initramfs.cpio.gz}"

log() {
  printf '[minibash:iso] %s\n' "$*"
}

find_first() {
  for p in "$@"; do
    if [ -f "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

main() {
  [ -f "$KERNEL_IMAGE" ] || {
    echo "missing kernel image: $KERNEL_IMAGE; run build.sh first or set KERNEL_IMAGE" >&2
    exit 1
  }
  [ -f "$INITRAMFS_IMAGE" ] || {
    echo "missing initramfs image: $INITRAMFS_IMAGE; run build.sh first or set INITRAMFS_IMAGE" >&2
    exit 1
  }

  isolinux_bin="$(find_first \
    /usr/lib/ISOLINUX/isolinux.bin \
    /usr/lib/syslinux/modules/bios/isolinux.bin)"
  ldlinux_c32="$(find_first \
    /usr/lib/syslinux/modules/bios/ldlinux.c32 \
    /usr/lib/SYSLINUX/ldlinux.c32)"
  isohdpfx="$(find_first \
    /usr/lib/ISOLINUX/isohdpfx.bin \
    /usr/lib/syslinux/mbr/isohdpfx.bin \
    /usr/lib/SYSLINUX/isohdpfx.bin)"

  rm -rf "$ISO_ROOT"
  rm -f "$EFI_IMG"
  mkdir -p "$ISO_ROOT/isolinux" "$ISO_ROOT/minibash" "$ISO_ROOT/EFI/BOOT"

  cp "$KERNEL_IMAGE" "$ISO_ROOT/minibash/bzImage"
  cp "$INITRAMFS_IMAGE" "$ISO_ROOT/minibash/initramfs.cpio.gz"
  cp "$KERNEL_IMAGE" "$ISO_ROOT/kernel"
  cp "$INITRAMFS_IMAGE" "$ISO_ROOT/initrd.gz"
  cp "$isolinux_bin" "$ISO_ROOT/isolinux/isolinux.bin"
  cp "$ldlinux_c32" "$ISO_ROOT/isolinux/ldlinux.c32"

  cat > "$ISO_ROOT/isolinux/isolinux.cfg" <<'CFG'
PROMPT 0
TIMEOUT 50
DEFAULT live

LABEL live
  KERNEL /kernel
  INITRD /initrd.gz
  APPEND console=tty0 init=/init panic=0 quiet loglevel=3 minibash.keymap=fr

LABEL autologin
  KERNEL /kernel
  INITRD /initrd.gz
  APPEND console=ttyS0 init=/init panic=0 quiet loglevel=3 minibash.autologin=root minibash.keymap=us
CFG

  grub_cfg="/tmp/minibash-grub.cfg"
  cat > "$grub_cfg" <<'CFG'
insmod part_gpt
insmod part_msdos
insmod fat
insmod iso9660
insmod search
insmod search_fs_file
insmod linux
insmod efi_gop
insmod efi_uga
insmod all_video

set timeout=5
set default=0
terminal_input console
terminal_output console
set gfxmode=auto
set gfxpayload=keep

menuentry "minibash-linux live" {
  search --no-floppy --file --set=root /kernel
  echo "boot root: $root"
  linux ($root)/kernel console=tty0 init=/init panic=0 loglevel=4 minibash.tty=tty1 minibash.autologin=root minibash.keymap=fr
  initrd ($root)/initrd.gz
}

menuentry "minibash-linux live qwerty" {
  search --no-floppy --file --set=root /kernel
  echo "boot root: $root"
  linux ($root)/kernel console=tty0 init=/init panic=0 loglevel=4 minibash.tty=tty1 minibash.autologin=root minibash.keymap=us
  initrd ($root)/initrd.gz
}

menuentry "minibash-linux live serial debug" {
  serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
  terminal_output serial
  search --no-floppy --file --set=root /kernel
  echo "boot root: $root"
  linux ($root)/kernel console=ttyS0 init=/init panic=0 loglevel=7 minibash.tty=ttyS0 minibash.autologin=root minibash.keymap=us
  initrd ($root)/initrd.gz
}
CFG

  grub-mkstandalone \
    -O x86_64-efi \
    --modules="part_gpt part_msdos fat iso9660 search search_fs_file linux normal configfile efi_gop efi_uga all_video" \
    -o "$ISO_ROOT/EFI/BOOT/BOOTX64.EFI" \
    "boot/grub/grub.cfg=$grub_cfg" >/dev/null

  dd if=/dev/zero of="$EFI_IMG" bs=1M count=64 2>/dev/null
  mkfs.vfat "$EFI_IMG" >/dev/null
  mmd -i "$EFI_IMG" ::/EFI ::/EFI/BOOT ::/minibash
  mcopy -i "$EFI_IMG" "$ISO_ROOT/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
  mcopy -i "$EFI_IMG" "$ISO_ROOT/minibash/bzImage" ::/minibash/bzImage
  mcopy -i "$EFI_IMG" "$ISO_ROOT/minibash/initramfs.cpio.gz" ::/minibash/initramfs.cpio.gz
  mcopy -i "$EFI_IMG" "$ISO_ROOT/kernel" ::/kernel
  mcopy -i "$EFI_IMG" "$ISO_ROOT/initrd.gz" ::/initrd.gz
  cp "$EFI_IMG" "$ISO_ROOT/EFI/efiboot.img"

  log "building hybrid ISO: $ISO"
  mkdir -p "$OUT_DIR"
  xorriso -as mkisofs \
    -o "$ISO" \
    -isohybrid-mbr "$isohdpfx" \
    -c isolinux/boot.cat \
    -b isolinux/isolinux.bin \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e EFI/efiboot.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -V MINIBASH \
    "$ISO_ROOT" >/dev/null

  log "iso: $ISO"
}

main "$@"
