#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

log_file="out/boot-smoke.log"
disk="out/smoke-disk.img"
mkdir -p out

# Fresh disk each run so we exercise the format-on-first-boot path.
rm -f "$disk"
dd if=/dev/zero of="$disk" bs=1M count=64 2>/dev/null

set +e
docker run --rm --platform linux/amd64 -v "$(cd .. && pwd)":/work minibash-linux-builder \
  timeout 45s qemu-system-x86_64 \
    -m 1024 \
    -no-reboot \
    -kernel /work/minibash-linux/out/bzImage \
    -initrd /work/minibash-linux/out/minibash-linux-initramfs.cpio.gz \
    -append "console=ttyS0 init=/init panic=0 quiet loglevel=3 minibash.autologin=root" \
    -drive file=/work/minibash-linux/out/smoke-disk.img,format=raw,if=virtio \
    -netdev user,id=net0,hostfwd=tcp::8080-:80 \
    -device e1000,netdev=net0 \
    -nographic > "$log_file" 2>&1
status="$?"
set -e

if [ "$status" != "124" ] && [ "$status" != "0" ]; then
  cat "$log_file"
  echo "boot smoke failed: qemu status $status" >&2
  exit 1
fi

# PID 1 (minit, Rust) came up
grep -q "\\[minit\\] booting minibash linux" "$log_file"
grep -q "\\[minit\\] ready" "$log_file"
# persistent disk was formatted and mounted
grep -q "/dev/vda at /var/bdb" "$log_file"
# database loaded (13 services seeded)
grep -q "\\[bdbboot:rust\\] 13 services loaded from bdb" "$log_file"
# the interactive console is opened promptly (getty-style)
grep -q "\\[minit\\] opening console shell" "$log_file"
# supervisor started the desired=up services
grep -q "\\[minit\\] start clock" "$log_file"
grep -q "\\[minit\\] start web" "$log_file"
grep -q "\\[minit\\] start metrics" "$log_file"
grep -q "\\[minit\\] start cron" "$log_file"
grep -q "\\[minit\\] start netd" "$log_file"
grep -q "\\[minit\\] start syslog" "$log_file"
grep -q "\\[minit\\] start healthd" "$log_file"
grep -q "\\[minit\\] start pkgd" "$log_file"
grep -q "\\[minit\\] start updated" "$log_file"
# login (autologin=root from the kernel cmdline) reached a shell session
grep -q "Welcome to minibash-linux, root" "$log_file"
# worker is desired=down and must NOT be auto-started
if grep -q "\\[minit\\] start worker" "$log_file"; then
  cat "$log_file"
  echo "boot smoke failed: worker should not autostart (desired=down)" >&2
  exit 1
fi
if grep -q "\\[minit\\] start installer" "$log_file"; then
  cat "$log_file"
  echo "boot smoke failed: installer should not autostart (desired=down)" >&2
  exit 1
fi
if grep -q "\\[minit\\] start sshd" "$log_file"; then
  cat "$log_file"
  echo "boot smoke failed: sshd should not autostart (desired=down)" >&2
  exit 1
fi
if grep -q "\\[minit\\] start desktopd" "$log_file"; then
  cat "$log_file"
  echo "boot smoke failed: desktopd should not autostart (desired=down)" >&2
  exit 1
fi

echo "boot smoke ok"
