#!/usr/bin/env bash
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

if pgrep -x rtkit-daemon >/dev/null 2>&1; then
  echo "rtkit: already running"
  exec sleep infinity
fi

for r in /usr/libexec/rtkit-daemon /usr/lib/rtkit/rtkit-daemon; do
  if [ -x "$r" ]; then
    echo "rtkit: starting $r"
    exec "$r" --no-canary --no-drop-privileges --no-chroot
  fi
done

echo "rtkit: binary missing"
exec sleep infinity
