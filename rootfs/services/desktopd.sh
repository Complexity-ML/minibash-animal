#!/usr/bin/env bash
# Minimal graphical desktop launcher. Weston is optional at runtime; if the GPU
# stack is not available, this service keeps reporting and the TTY dashboard
# remains usable through /bin/desktop.
set -u

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}"
export HOME="${HOME:-/root}"
export USER="${USER:-root}"
export LOGNAME="${LOGNAME:-root}"
export PATH=/bin:/usr/bin:/sbin:/usr/sbin:/services

mkdir -p "$XDG_RUNTIME_DIR" "$HOME/.config" /var/log
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

write_config() {
  mkdir -p /etc/xdg/weston
  cat > /etc/xdg/weston/weston.ini <<'EOF'
[core]
idle-time=0

[shell]
locking=false
panel-position=top
startup-animation=none

[terminal]
font=monospace
font-size=13
EOF
}

launch_terminal() {
  sleep 3
  if command -v foot >/dev/null 2>&1; then
    WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}" foot /bin/desktop >/var/log/desktop-terminal.log 2>&1 &
  elif command -v weston-terminal >/dev/null 2>&1; then
    WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}" weston-terminal >/var/log/desktop-terminal.log 2>&1 &
  fi
}

if ! command -v weston >/dev/null 2>&1; then
  echo "desktopd: weston missing; trying optional desktop payload"
  /bin/desktop-install --auto || true
fi

if ! command -v weston >/dev/null 2>&1; then
  echo "desktopd: weston still missing; use /bin/desktop on the console"
  while true; do sleep 60; done
fi

write_config
echo "desktopd: starting weston"
launch_terminal &

while true; do
  if weston --backend=drm-backend.so --tty=2 --config=/etc/xdg/weston/weston.ini --log=/var/log/weston.log; then
    echo "desktopd: weston exited cleanly"
  else
    echo "desktopd: weston failed; see /var/log/weston.log"
  fi
  sleep 5
done
