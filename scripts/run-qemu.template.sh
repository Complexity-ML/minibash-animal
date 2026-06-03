#!/usr/bin/env bash
set -euo pipefail

DIR="__OUT_DIR__"
DISK="$DIR/minibash-disk.img"

# Persistent storage: a 256 MiB raw disk, created once and reused across boots.
# minit formats it ext2 on first boot and mounts it at /var/bdb, so the database
# (services, desired state, users, logs) survives reboots.
if [ ! -f "$DISK" ]; then
  echo "creating persistent disk $DISK (256 MiB)"
  dd if=/dev/zero of="$DISK" bs=1M count=256 2>/dev/null
fi

# -no-reboot: a guest reboot/poweroff makes QEMU exit instead of resetting.
# user-mode net + hostfwd: best-effort; the web service also listens on lo.
# Login: the console runs /bin/login (user root / password root). To auto-login,
#   add e.g. minibash.autologin=root to -append.
qemu-system-x86_64 \
  -m 1024 \
  -no-reboot \
  -kernel "$DIR/bzImage" \
  -initrd "$DIR/minibash-linux-initramfs.cpio.gz" \
  -append "console=ttyS0 init=/init panic=0 quiet loglevel=3" \
  -drive file="$DISK",format=raw,if=virtio \
  -netdev user,id=net0,hostfwd=tcp::8080-:80 \
  -device e1000,netdev=net0 \
  -nographic
