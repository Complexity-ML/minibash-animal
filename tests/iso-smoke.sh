#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

log_file="out/iso-smoke.log"
mkdir -p out

set +e
docker run --rm --platform linux/amd64 -v "$(cd .. && pwd)":/work minibash-linux-builder \
  timeout 55s qemu-system-x86_64 \
    -m 1024 \
    -no-reboot \
    -cdrom /work/minibash-linux/out/minibash-linux.iso \
    -boot d \
    -nographic > "$log_file" 2>&1
status="$?"
set -e

if [ "$status" != "124" ] && [ "$status" != "0" ]; then
  cat "$log_file"
  echo "iso smoke failed: qemu status $status" >&2
  exit 1
fi

grep -q "\\[minit\\] booting minibash linux" "$log_file"
grep -q "\\[bdbboot:rust\\] 13 services loaded from bdb" "$log_file"
grep -q "minibash login:" "$log_file"

echo "iso smoke ok"
