#!/usr/bin/env bash
set -euo pipefail

DISTRO_DIR="${DISTRO_DIR:-/work/minibash-linux}"
OUT_DIR="${OUT_DIR:-$DISTRO_DIR/out}"
USB_IMG="${USB_IMG:-$OUT_DIR/minibash-linux-usb.img}"
KERNEL_IMAGE="${KERNEL_IMAGE:-$OUT_DIR/debian-vmlinuz}"
INITRAMFS_IMAGE="${INITRAMFS_IMAGE:-$OUT_DIR/minibash-linux-initramfs.cpio.gz}"
IMG_SIZE_MB="${IMG_SIZE_MB:-256}"
EFI_SIZE_MB="${EFI_SIZE_MB:-96}"
PART_OFFSET_BYTES="${PART_OFFSET_BYTES:-1048576}"
DESKTOP_PAYLOAD_TAR="${DESKTOP_PAYLOAD_TAR:-}"
DESKTOP_PAYLOAD_MANIFEST="${DESKTOP_PAYLOAD_MANIFEST:-}"

log() {
  printf '[minibash:usb] %s\n' "$*"
}

main() {
  [ -f "$KERNEL_IMAGE" ] || {
    echo "missing kernel image: $KERNEL_IMAGE" >&2
    exit 1
  }
  [ -f "$INITRAMFS_IMAGE" ] || {
    echo "missing initramfs image: $INITRAMFS_IMAGE" >&2
    exit 1
  }
  if [ -n "$DESKTOP_PAYLOAD_TAR" ]; then
    [ -f "$DESKTOP_PAYLOAD_TAR" ] || {
      echo "missing desktop payload: $DESKTOP_PAYLOAD_TAR" >&2
      exit 1
    }
    IMG_SIZE_MB="${IMG_SIZE_MB:-512}"
    if [ "$IMG_SIZE_MB" -lt 512 ]; then
      IMG_SIZE_MB=512
    fi
  fi

  mkdir -p "$OUT_DIR"
  rm -f "$USB_IMG"
  dd if=/dev/zero of="$USB_IMG" bs=1M count="$IMG_SIZE_MB" status=none

  if [ -n "$DESKTOP_PAYLOAD_TAR" ]; then
    efi_part_size_mb="$EFI_SIZE_MB"
    efi_sectors=$((efi_part_size_mb * 1024 * 1024 / 512))
    data_start_sectors=$((2048 + efi_sectors))
    data_offset_bytes=$((data_start_sectors * 512))
    data_size_mb=$((IMG_SIZE_MB - EFI_SIZE_MB - 2))
    sfdisk "$USB_IMG" >/dev/null <<EOF
label: gpt
unit: sectors
first-lba: 2048

start=2048, size=${EFI_SIZE_MB}M, type=uefi, name="MINIBASH"
start=${data_start_sectors}, type=linux, name="MINIBASHDATA"
EOF
  else
    efi_part_size_mb=$((IMG_SIZE_MB - 2))
    sfdisk "$USB_IMG" >/dev/null <<EOF
label: gpt
unit: sectors
first-lba: 2048

start=2048, type=uefi, name="MINIBASH"
EOF
  fi

  efi_img="$(mktemp)"
  dd if=/dev/zero of="$efi_img" bs=1M count="$efi_part_size_mb" status=none

  mformat -i "$efi_img" -F -v MINIBASH ::
  mmd -i "$efi_img" ::/EFI ::/EFI/BOOT

  grub_cfg="$(mktemp)"
  trap 'rm -f "$grub_cfg" "$efi_img"' EXIT
  cat > "$grub_cfg" <<'CFG'
set timeout=2
set default=0
terminal_input console
terminal_output console
set gfxmode=auto
set gfxpayload=keep

search --no-floppy --label MINIBASH --set=root

menuentry "minibash-linux live" {
  search --no-floppy --label MINIBASH --set=root
  echo "booting minibash-linux"
  linux /kernel console=tty0 init=/init panic=0 loglevel=4 minibash.tty=tty1 minibash.autologin=root
  initrd /initrd.gz
}

menuentry "minibash-linux live serial debug" {
  search --no-floppy --label MINIBASH --set=root
  serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
  terminal_output serial
  echo "booting minibash-linux serial"
  linux /kernel console=ttyS0 init=/init panic=0 loglevel=7 minibash.tty=ttyS0 minibash.autologin=root
  initrd /initrd.gz
}
CFG

  bootefi="$(mktemp)"
  grub-mkstandalone \
    -O x86_64-efi \
    --modules="part_gpt fat search search_label linux normal configfile efi_gop efi_uga all_video" \
    -o "$bootefi" \
    "boot/grub/grub.cfg=$grub_cfg" >/dev/null

  mcopy -i "$efi_img" "$bootefi" ::/EFI/BOOT/BOOTX64.EFI
  rm -f "$bootefi"
  mcopy -i "$efi_img" "$KERNEL_IMAGE" ::/kernel
  mcopy -i "$efi_img" "$INITRAMFS_IMAGE" ::/initrd.gz
  dd if="$efi_img" of="$USB_IMG" bs=512 seek=2048 conv=notrunc status=none

  if [ -n "$DESKTOP_PAYLOAD_TAR" ]; then
    payload_root="$(mktemp -d)"
    data_img="$(mktemp)"
    trap 'rm -f "$grub_cfg" "$efi_img" "$data_img"; rm -rf "$payload_root"' EXIT
    mkdir -p "$payload_root/minibash-desktop"
    cp "$DESKTOP_PAYLOAD_TAR" "$payload_root/minibash-desktop/desktop-root.tar.gz"
    if [ -n "$DESKTOP_PAYLOAD_MANIFEST" ] && [ -f "$DESKTOP_PAYLOAD_MANIFEST" ]; then
      cp "$DESKTOP_PAYLOAD_MANIFEST" "$payload_root/minibash-desktop/MANIFEST"
    else
      sha256sum "$DESKTOP_PAYLOAD_TAR" > "$payload_root/minibash-desktop/MANIFEST"
    fi
    dd if=/dev/zero of="$data_img" bs=1M count="$data_size_mb" status=none
    mke2fs -q -t ext2 -F -L MINIBASHDATA -d "$payload_root" "$data_img"
    dd if="$data_img" of="$USB_IMG" bs=512 seek="$data_start_sectors" conv=notrunc status=none
  fi

  log "usb image: $USB_IMG"
}

main "$@"
