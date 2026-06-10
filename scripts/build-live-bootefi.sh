#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/out/BOOTX64-live.EFI}"
GRUB_CFG="$(mktemp)"

cleanup() { rm -f "$GRUB_CFG"; }
trap cleanup EXIT

cat > "$GRUB_CFG" <<'CFG'
set default=1
set timeout=10
set timeout_style=menu
terminal_output console

menuentry "Altitude Linux 0.1 - current fallback" {
  search --no-floppy --label MINIBASHEFI --set=esp
  linux ($esp)/kernel root=LABEL=minibashroot rootfstype=ext4 rw fsck.repair=yes init=/init minibash.root=disk iwlmvm.power_scheme=1 console=tty0 panic=0 loglevel=4 minibash.tty=tty1 minibash.autologin=root minibash.keymap=fr
}

menuentry "Altitude Linux Native 0.1 - systemd desktop" {
  search --no-floppy --label MINIBASHEFI --set=esp
  linux ($esp)/altitude-native/kernel root=LABEL=altitude-native rootfstype=ext4 rw fsck.repair=yes init=/init altitude.init=systemd systemd.unit=graphical.target console=tty0 console=ttyS0,115200 panic=0 loglevel=4 minibash.tty=tty1 minibash.autologin=root minibash.keymap=fr
  initrd ($esp)/altitude-native/initrd.img
}

menuentry "Altitude Linux Native 0.1 - serial repair" {
  search --no-floppy --label MINIBASHEFI --set=esp
  linux ($esp)/altitude-native/kernel root=LABEL=altitude-native rootfstype=ext4 rw fsck.repair=yes init=/init altitude.init=systemd systemd.unit=multi-user.target console=ttyS0,115200 panic=0 loglevel=7 minibash.tty=ttyS0 minibash.autologin=root minibash.keymap=fr
  initrd ($esp)/altitude-native/initrd.img
}
CFG

mkdir -p "$(dirname "$OUT")"
grub-mkstandalone \
  -O x86_64-efi \
  --modules="part_gpt fat ext2 search search_label linux normal configfile efi_gop efi_uga all_video serial terminal" \
  -o "$OUT" \
  "boot/grub/grub.cfg=$GRUB_CFG" >/dev/null

ls -lh "$OUT"
