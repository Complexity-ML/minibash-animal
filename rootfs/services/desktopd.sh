#!/usr/bin/env bash
# Minimal graphical desktop launcher.
#
# Sway (wlroots) REFUSES to run as root, so we cannot launch it directly from
# this root service. The minimal, logind-free recipe is:
#   - run the tiny `seatd` daemon as root (it opens DRM/input devices and hands
#     fds to clients over /run/seatd.sock),
#   - run sway as the non-root `minibash` user (member of the seatd socket group
#     plus video/input/render), using libseat's seatd backend.
# No logind, no D-Bus, no PAM. If the GPU stack is missing the service keeps
# reporting and the TTY dashboard remains usable via /bin/desktop.
set -u

DESKTOP_USER=minibash
DESKTOP_UID=1000
DESKTOP_GID=1000
SEAT_GROUP=video
RUNTIME_DIR="/run/user/$DESKTOP_UID"
DESKTOP_HOME="/home/$DESKTOP_USER"
SWAY_CONFIG=/etc/sway/minibash.config
SWAY_LOG=/var/log/sway.log
SEATD_LOG=/var/log/seatd.log

export PATH=/bin:/usr/bin:/sbin:/usr/sbin:/services

log() { echo "desktopd: $*"; }

write_config() {
  mkdir -p /etc/sway
  cat > "$SWAY_CONFIG" <<'EOF'
# minibash minimal Sway session
set $mod Mod4

input "type:keyboard" {
    xkb_layout fr
}

# minibash dashboard terminal on startup
exec foot /bin/desktop

bindsym $mod+Return exec foot
bindsym $mod+d exec foot
bindsym $mod+Shift+q kill
bindsym $mod+Shift+e exit
bindsym $mod+f fullscreen

default_border pixel 2
EOF
  chmod 644 "$SWAY_CONFIG"
}

capture_hardware_log() {
  {
    echo "desktopd hardware snapshot"
    date 2>/dev/null || true
    echo
    echo "[cmdline]"; cat /proc/cmdline 2>/dev/null || true
    echo
    echo "[graphics devices]"; ls -l /dev/dri 2>/dev/null || echo "no /dev/dri"
    echo
    echo "[input devices]"; ls -l /dev/input 2>/dev/null || echo "no /dev/input"
    echo
    echo "[loaded graphics modules]"
    grep -E '(^drm|^drm_kms_helper|^i915|^amdgpu|^nouveau|^simpledrm|^virtio_gpu)' /proc/modules 2>/dev/null || true
    echo
    echo "[kernel graphics log]"
    dmesg 2>/dev/null | grep -Ei 'drm|i915|amdgpu|nouveau|simpledrm|virtio_gpu|fb0|firmware' || true
  } > /var/log/desktop-hardware.log
}

start_udev() {
  command -v udevadm >/dev/null 2>&1 || { log "udevadm missing; input may not be detected"; return 0; }
  mkdir -p /run/udev
  for d in /lib/systemd/systemd-udevd /usr/lib/systemd/systemd-udevd; do
    [ -x "$d" ] && { log "starting udevd ($d)"; "$d" --daemon; break; }
  done
  udevadm trigger --action=add --type=subsystems 2>/dev/null || true
  udevadm trigger --action=add --type=devices 2>/dev/null || true
  udevadm settle --timeout=10 2>/dev/null || true
}

ensure_gpu() {
  # Make sure a render-capable KMS driver is bound, not just the simpledrm EFI
  # framebuffer (wlroots cannot render on simpledrm: no GBM). minit loads these
  # too, but re-trying here is harmless and covers late firmware/probe.
  for m in i915 amdgpu nouveau virtio_gpu; do modprobe "$m" 2>/dev/null || true; done
  local i
  for ((i=0; i<15; i++)); do
    [ -e /dev/dri/renderD128 ] && return 0
    sleep 1
  done
  return 0
}

start_seatd() {
  command -v seatd >/dev/null 2>&1 || { log "seatd missing"; return 1; }
  if [ ! -S /run/seatd.sock ]; then
    log "starting seatd (socket group=$SEAT_GROUP)"
    seatd -g "$SEAT_GROUP" >"$SEATD_LOG" 2>&1 &
  fi
  local i
  for ((i=0; i<15; i++)); do
    [ -S /run/seatd.sock ] && return 0
    sleep 1
  done
  log "seatd socket not ready; see $SEATD_LOG"
  return 1
}

prepare_user() {
  mkdir -p "$RUNTIME_DIR" "$DESKTOP_HOME/.config"
  chown -R "$DESKTOP_UID:$DESKTOP_GID" "$RUNTIME_DIR" "$DESKTOP_HOME" 2>/dev/null || true
  chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
}

pick_gpu() {
  # Prefer a real render-capable GPU over the simpledrm EFI framebuffer, which
  # wlroots cannot use. Read DRIVER= from each card's uevent (no readlink needed).
  local d driver
  for d in /sys/class/drm/card[0-9]*; do
    [ -e "$d/device/uevent" ] || continue
    driver=$(grep -h '^DRIVER=' "$d/device/uevent" 2>/dev/null | cut -d= -f2)
    case "$driver" in
      simpledrm|simple-framebuffer|efi-framebuffer|efifb|vesafb|"") continue ;;
    esac
    export WLR_DRM_DEVICES="/dev/dri/${d##*/}"
    log "selected GPU ${d##*/} (driver=$driver) for wlroots"
    return 0
  done
  log "no dedicated GPU detected; letting wlroots auto-pick"
}

run_sway() {
  log "starting sway as $DESKTOP_USER on VT2 (seatd; WLR_DRM_DEVICES=${WLR_DRM_DEVICES:-auto})"
  # A detached service has no controlling VT, so seatd cannot activate a seat and
  # sway hangs on a black screen. openvt allocates VT2, switches to it and gives
  # sway a real controlling terminal there.
  cat > /run/sway-session.sh <<EOF
#!/bin/bash
echo "sway-session: launching \$(date 2>/dev/null)" > "$SWAY_LOG"
exec setpriv --reuid $DESKTOP_UID --regid $DESKTOP_GID --init-groups \\
  env HOME=$DESKTOP_HOME USER=$DESKTOP_USER LOGNAME=$DESKTOP_USER \\
      LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \\
      XDG_RUNTIME_DIR=$RUNTIME_DIR XDG_SESSION_TYPE=wayland \\
      LIBSEAT_BACKEND=seatd WLR_RENDERER_ALLOW_SOFTWARE=1 \\
      ${WLR_DRM_DEVICES:+WLR_DRM_DEVICES=$WLR_DRM_DEVICES} \\
      PATH=/bin:/usr/bin:/sbin:/usr/sbin \\
      sway -d -c $SWAY_CONFIG >> "$SWAY_LOG" 2>&1
EOF
  chmod +x /run/sway-session.sh
  openvt -c 2 -s -w /bin/bash /run/sway-session.sh
}

if ! command -v sway >/dev/null 2>&1; then
  log "sway missing; use /bin/desktop on the console"
  while true; do sleep 60; done
fi

write_config
start_udev
ensure_gpu
pick_gpu
capture_hardware_log

if [ ! -e /dev/dri/card0 ] && [ ! -e /dev/dri/renderD128 ]; then
  log "no /dev/dri GPU device; staying on console"
  command -v chvt >/dev/null 2>&1 && chvt 1 >/dev/null 2>&1 || true
  while true; do log "no gpu; inspect /var/log/desktop-hardware.log"; sleep 30; done
fi

if ! start_seatd; then
  log "seatd unavailable; cannot start the desktop"
  while true; do log "inspect $SEATD_LOG"; sleep 30; done
fi

prepare_user

if run_sway; then
  log "sway exited cleanly"
  exit 0
fi

log "sway failed; see $SWAY_LOG"
capture_hardware_log
tail -n 30 "$SWAY_LOG" 2>/dev/null || true
command -v chvt >/dev/null 2>&1 && chvt 1 >/dev/null 2>&1 || true
while true; do
  log "desktop unavailable; inspect $SWAY_LOG $SEATD_LOG /var/log/desktop-hardware.log"
  sleep 5
done
