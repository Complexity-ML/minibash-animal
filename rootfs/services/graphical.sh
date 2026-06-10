#!/usr/bin/env bash
# Start the Altitude GNOME desktop without systemd or a display manager.
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
exec >>/var/log/graphical.log 2>&1

VT="${ALTITUDE_GRAPHICAL_VT:-2}"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}"

log() { echo "graphical: $* ($(date 2>/dev/null))"; }

wait_bus_name() {
  local name="$1" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    busctl --system --no-pager list 2>/dev/null | awk '{print $1}' | grep -qx "$name" && return 0
    sleep 1
  done
  return 1
}

start_if_missing() {
  local name="$1" proc="$2"; shift 2
  if pgrep -x "$proc" >/dev/null 2>&1 && wait_bus_name "$name"; then
    return 0
  fi
  if [ ! -x "$1" ]; then
    log "skipping missing service $proc ($1)"
    return 0
  fi
  "$@" >/var/log/"$proc"-graphical.log 2>&1 &
  wait_bus_name "$name" || true
}

cleanup() {
  log "stopping GNOME session"
  killall gnome-shell 2>/dev/null || true
}
trap '' HUP
trap cleanup TERM INT

udevd_running() {
  pgrep -x systemd-udevd >/dev/null 2>&1 || pgrep -x udevd >/dev/null 2>&1 || \
    ps -ef | grep -Eq '[/](usr/)?sbin/udevd'
}

# GPU, input and seat plumbing. HP Omen uses NVIDIA TU116 as the visible panel
# device, so nouveau must be present before udev cold-plugs DRM.
for m in evdev mousedev usbhid hid_generic i2c_hid i2c_hid_acpi psmouse \
         mxm-wmi drm_ttm_helper gpu-sched nouveau i915 amdgpu radeon \
         virtio_gpu simpledrm; do
  modprobe "$m" 2>/dev/null || true
done

mkdir -p /run/udev /run/udev/data "$RUNTIME_DIR" /run/dbus /run/elogind \
  /run/systemd/seats /run/systemd/sessions /run/systemd/users
chmod 700 "$RUNTIME_DIR" 2>/dev/null || true

if ! udevd_running; then
  log "starting udevd"
  /usr/sbin/udevd --daemon 2>/var/log/udevd.log || /sbin/udevd --daemon 2>/var/log/udevd.log || true
fi

if command -v udevadm >/dev/null 2>&1; then
  udevadm trigger --action=add >/dev/null 2>&1 || true
  udevadm settle --timeout=10 >/dev/null 2>&1 || true
fi

if [ ! -s /etc/machine-id ]; then
  dbus-uuidgen --ensure=/etc/machine-id 2>/dev/null || tr -d '-' < /proc/sys/kernel/random/uuid > /etc/machine-id
fi
[ -s /var/lib/dbus/machine-id ] || { mkdir -p /var/lib/dbus; cp /etc/machine-id /var/lib/dbus/machine-id; }

[ -S /run/dbus/system_bus_socket ] || { log "starting dbus fallback"; dbus-daemon --system --fork --nopidfile; }

if ! pgrep -x elogind >/dev/null 2>&1; then
  rm -f /run/elogind.pid /run/systemd/seats/* /run/systemd/sessions/* /run/systemd/users/* 2>/dev/null || true
fi
start_if_missing org.freedesktop.login1 elogind /usr/libexec/elogind
start_if_missing org.freedesktop.UPower upowerd /usr/libexec/upowerd --verbose
start_if_missing org.freedesktop.Accounts accounts-daemon /usr/libexec/accounts-daemon
start_if_missing org.freedesktop.PolicyKit1 polkitd /usr/lib/polkit-1/polkitd --no-debug
start_if_missing org.freedesktop.RealtimeKit1 rtkit-daemon /services/rtkit.sh

cat > /run/altitude-gnome-session <<'EOF'
#!/bin/sh
set -u

VT="${ALTITUDE_GRAPHICAL_VT:-2}"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}"
LOG=/var/log/gnome-shell.log

export TZ="${TZ:-UTC}"
export XDG_RUNTIME_DIR="$RUNTIME_DIR"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_SESSION_TYPE=wayland
export XDG_CURRENT_DESKTOP=GNOME
export XDG_SESSION_DESKTOP=altitude
export GNOME_SHELL_SESSION_MODE=altitude
export GIO_USE_VFS=local

mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
rm -f "$XDG_RUNTIME_DIR"/gnome-shell-disable-extensions "$XDG_RUNTIME_DIR"/wayland-*

resp="$(busctl --system call \
  org.freedesktop.login1 \
  /org/freedesktop/login1 \
  org.freedesktop.login1.Manager \
  CreateSession 'uusssssussbssa(sv)' \
  0 "$$" altitude wayland user altitude seat0 "$VT" "tty$VT" "" false "" "" 0)"

echo "CreateSession: $resp" >"$LOG"
sid="$(printf "%s\n" "$resp" | awk '{print $2}' | tr -d '"')"
export XDG_SESSION_ID="$sid"
echo "XDG_SESSION_ID=$XDG_SESSION_ID PID=$$" >>"$LOG"
echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR WAYLAND_DISPLAY=$WAYLAND_DISPLAY" >>"$LOG"

dbus_info="$(dbus-daemon --session --fork --print-address=1 --print-pid=1)"
export DBUS_SESSION_BUS_ADDRESS="$(printf "%s\n" "$dbus_info" | sed -n '1p')"
echo "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS" >>"$LOG"

if command -v gsettings >/dev/null 2>&1; then
  gsettings set org.gnome.desktop.interface enable-animations false >/dev/null 2>&1 || true
  gsettings set org.gnome.desktop.search-providers disable-external true >/dev/null 2>&1 || true
fi

gnome-shell --wayland --display-server >>"$LOG" 2>&1
status=$?
busctl --system call org.freedesktop.login1 /org/freedesktop/login1 \
  org.freedesktop.login1.Manager ReleaseSession s "$XDG_SESSION_ID" >/dev/null 2>&1 || true
exit "$status"
EOF
chmod +x /run/altitude-gnome-session

if pgrep -x gnome-shell >/dev/null 2>&1; then
  log "gnome-shell already running"
  exec sleep infinity
fi

log "starting GNOME on tty$VT"
if command -v openvt >/dev/null 2>&1; then
  openvt -c "$VT" -f -s -- /run/altitude-gnome-session &
else
  /run/altitude-gnome-session &
fi

while pgrep -x gnome-shell >/dev/null 2>&1 || pgrep -f /run/altitude-gnome-session >/dev/null 2>&1; do
  sleep 10
done

log "GNOME exited"
exit 1
