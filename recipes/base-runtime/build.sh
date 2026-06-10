#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/base-runtime}"
TOOLCHAIN=/opt/altitude/toolchain
TARGET=x86_64-altitude-linux-gnu
CC="$TOOLCHAIN/bin/x86_64-altitude-linux-gnu-gcc"
READELF="$TOOLCHAIN/bin/x86_64-altitude-linux-gnu-readelf"
BUSYBOX_WORK="${ALTITUDE_BUSYBOX_WORK:-$ROOT/out/source-work/busybox}"
BASH_WORK="${ALTITUDE_BASH_WORK:-$ROOT/out/source-work/bash}"
BUSYBOX="$BUSYBOX_WORK/payload/usr/libexec/altitude/busybox"
BASH="$BASH_WORK/payload/bin/bash"
PAYLOAD="$WORK/payload"
GLIBC_LIBDIR="$TOOLCHAIN/sysroot/usr/lib"
GCC_RUNTIME_LIBDIR="$TOOLCHAIN/$TARGET/lib64"
GLIBC_LOADER="$GLIBC_LIBDIR/ld-linux-x86-64.so.2"
GLIBC_LIBC="$GLIBC_LIBDIR/libc.so.6"

for input in "$CC" "$READELF" "$BUSYBOX" "$BASH" \
  "$GLIBC_LOADER" "$GLIBC_LIBC" \
  "$GCC_RUNTIME_LIBDIR/libgcc_s.so.1" "$GCC_RUNTIME_LIBDIR/libstdc++.so.6.0.33" \
  "$ROOT/rootfs/usr/src/minibash/bdbc.c"; do
  [ -e "$input" ] || {
    echo "base-runtime: missing build input: $input" >&2
    exit 1
  }
done

rm -rf "$WORK"
mkdir -p "$PAYLOAD"/{bin,sbin,etc,proc,sys,dev,run,tmp,root,home,var/log} \
  "$PAYLOAD/usr/lib/modules" "$PAYLOAD/usr/share/altitude/sources"
ln -s ../run "$PAYLOAD/var/run"

install -m755 "$BUSYBOX" "$PAYLOAD/bin/busybox"
install -m755 "$BASH" "$PAYLOAD/bin/bash"
install -d "$PAYLOAD/usr/lib"
for lib in \
  ld-linux-x86-64.so.2 libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 \
  libresolv.so.2 librt.so.1 libutil.so.1 libanl.so.1 libnss_files.so.2 \
  libnss_dns.so.2; do
  [ -e "$GLIBC_LIBDIR/$lib" ] || continue
  cp -a "$GLIBC_LIBDIR/$lib" "$PAYLOAD/usr/lib/"
done
cp -a "$GCC_RUNTIME_LIBDIR"/libgcc_s.so* "$PAYLOAD/usr/lib/"
cp -a "$GCC_RUNTIME_LIBDIR"/libstdc++.so* "$PAYLOAD/usr/lib/"
ln -s bash "$PAYLOAD/bin/sh"
while IFS= read -r applet; do
  case "$applet" in
    ""|bash|sh|login|dpkg|dpkg-deb|rpm|rpm2cpio) continue ;;
  esac
  [ -e "$PAYLOAD/bin/$applet" ] ||
    ln -s busybox "$PAYLOAD/bin/$applet"
done < <("$BUSYBOX" --list)
for applet in init modprobe insmod depmod reboot poweroff halt; do
  ln -sf ../bin/busybox "$PAYLOAD/sbin/$applet"
done
[ -e "$PAYLOAD/bin/getty" ] && ln -sf ../bin/getty "$PAYLOAD/sbin/agetty"
cat > "$PAYLOAD/init" <<'EOF'
#!/bin/sh
# Altitude native PID 1. Keep this slot self-contained: kernel Altitude + root
# altitude-native + Altitude services only.
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/services
export PATH

mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
[ -c /dev/console ] || mknod /dev/console c 5 1 2>/dev/null || true
[ -c /dev/null ] || mknod /dev/null c 1 3 2>/dev/null || true
mkdir -p /proc /sys /dev/pts /dev/shm /run /tmp /var/log /root
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true
mount -t tmpfs tmpfs /run 2>/dev/null || true
chmod 1777 /tmp /dev/shm 2>/dev/null || true

LOG=/var/log/altitude-init.log
log() {
  echo "altitude-init: $*" >>"$LOG"
  echo "altitude-init: $*" >/dev/console 2>/dev/null || true
}

root_line="$(awk '$2=="/" {print $1 " " $3 " " $4; exit}' /proc/mounts 2>/dev/null)"
log "PID1 start $(date 2>/dev/null || true)"
log "cmdline: $(cat /proc/cmdline 2>/dev/null)"
log "root: ${root_line:-unknown}"

case " $(cat /proc/cmdline 2>/dev/null) " in
  *" altitude.init=systemd "*)
    if [ -x /usr/lib/systemd/systemd ]; then
      log "exec systemd PID1"
      exec /usr/lib/systemd/systemd
      log "systemd exec failed rc=$?"
    else
      log "systemd requested but /usr/lib/systemd/systemd is missing; using BusyBox fallback"
    fi
    ;;
esac

if [ -x /etc/rc.altitude ]; then
  log "running /etc/rc.altitude"
  /bin/bash /etc/rc.altitude >>/var/log/rc.altitude.log 2>&1 || log "rc.altitude exited rc=$?"
else
  log "missing /etc/rc.altitude"
fi

# Last-resort network repair: rc.altitude should already start these, but PID1
# keeps them alive enough for remote debugging if the service list regresses.
if [ -x /services/wifi.sh ] && ! pgrep -f '/services/wifi.sh' >/dev/null 2>&1; then
  log "starting wifi fallback"
  setsid /services/wifi.sh >>/var/log/service-wifi-pid1.log 2>&1 &
fi
if [ -x /services/sshd.sh ] && ! pgrep -x dropbear >/dev/null 2>&1; then
  log "starting sshd fallback"
  setsid /services/sshd.sh >>/var/log/service-sshd-pid1.log 2>&1 &
fi

log "native runtime ready; opening tty1 rescue shell"
while true; do
  if [ -c /dev/tty1 ]; then
    setsid /bin/sh -l </dev/tty1 >/dev/tty1 2>&1
  else
    /bin/sh -l </dev/console >/dev/console 2>&1
  fi
  log "console shell exited; respawn in 2s"
  sleep 2
done
EOF
chmod 755 "$PAYLOAD/init"
: > "$PAYLOAD/etc/machine-id"

"$CC" -O2 -static -Wall -Wextra \
  -o "$PAYLOAD/bin/bdbc" "$ROOT/rootfs/usr/src/minibash/bdbc.c"
ldd_output="$(ldd "$PAYLOAD/bin/bdbc" 2>&1 || true)"
if command -v ldd >/dev/null 2>&1; then
  grep -Eq 'not a dynamic executable|statically linked' <<< "$ldd_output"
else
  ! "$READELF" -l "$PAYLOAD/bin/bdbc" | grep -q 'Requesting program interpreter'
fi

for path in \
  bin/altitude bin/bdb bin/bdbql bin/bdbsh bin/bdbctl bin/bdbreg bin/bdbconf \
  bin/appreg bin/systemd-audit bin/login bin/passwd bin/pkg bin/altpkg-build bin/altrepo \
  bin/altitude-software \
  etc/altitude etc/minibash etc/systemd etc/os-release etc/lsb-release etc/hostname \
  etc/issue etc/passwd etc/group etc/shells services; do
  [ -e "$ROOT/rootfs/$path" ] || continue
  mkdir -p "$PAYLOAD/$(dirname "$path")"
  rm -rf "$PAYLOAD/$path"
  cp -a "$ROOT/rootfs/$path" "$PAYLOAD/$path"
done
find "$PAYLOAD/bin" -type f -exec chmod 755 {} +
find "$PAYLOAD/services" -type f -name '*.sh' -exec chmod 755 {} +

cat > "$PAYLOAD/etc/inittab" <<'EOF'
::sysinit:/etc/rc.altitude
tty1::respawn:/bin/login
ttyS0::respawn:/bin/login
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
EOF
cat > "$PAYLOAD/etc/rc.altitude" <<'EOF'
#!/bin/bash
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/services
export BDB_PATH=/var/bdb
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts /dev/shm /run /tmp /var/log /var/bdb /root
mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true
mount -t tmpfs tmpfs /run 2>/dev/null || true
chmod 1777 /tmp /dev/shm
ln -sfn /proc/self/fd /dev/fd
hostname altitude
echo /sbin/modprobe > /proc/sys/kernel/modprobe 2>/dev/null || true
if [ ! -f /var/bdb/tables/registry/data.bdb ]; then
  cp -a /etc/minibash/bdb/. /var/bdb/
fi

# Bring WiFi up early, then SSH. Dropbear can listen before DHCP finishes, so
# remote repair remains available as soon as the WiFi lease appears.
if [ -x /services/wifi.sh ] && ! pgrep -f '/services/wifi.sh' >/dev/null 2>&1; then
  setsid /services/wifi.sh >>/var/log/service-wifi-early.log 2>&1 &
fi

if [ -x /services/sshd.sh ] && ! pgrep -x dropbear >/dev/null 2>&1; then
  setsid /services/sshd.sh >>/var/log/service-sshd-early.log 2>&1 &
fi

# Native boot services are external scripts, not BDB rows. Systemd can replace
# this list later; the BDB only audits systemd state through systemd_audit.
for name in keymap kmod mountd sysctld clock syslog netd netmgr healthd metrics cron updated pkgd web; do
  cmd="/services/$name.sh"
  [ -x "$cmd" ] || continue
  echo "[altitude] start $name"
  setsid "$cmd" >>"/var/log/service-$name.log" 2>&1 &
done

if [ -x /services/sshd.sh ] && ! pgrep -x dropbear >/dev/null 2>&1; then
  setsid /services/sshd.sh >>/var/log/service-sshd-fallback.log 2>&1 &
fi

if [ -x /services/wifi.sh ] && ! pgrep -f '/services/wifi.sh' >/dev/null 2>&1; then
  setsid /services/wifi.sh >>/var/log/service-wifi-fallback.log 2>&1 &
fi

desktop_enabled=0
[ "${ALTITUDE_AUTO_GRAPHICAL:-}" = "1" ] && desktop_enabled=1
[ -e /etc/altitude/desktop.enabled ] && desktop_enabled=1
if [ "$desktop_enabled" = "1" ]; then
  if [ -x /services/graphical.sh ] && command -v gnome-shell >/dev/null 2>&1; then
    if ! pgrep -x gnome-shell >/dev/null 2>&1 &&
       ! pgrep -f '/services/graphical.sh' >/dev/null 2>&1; then
      echo "[altitude] start graphical"
      ALTITUDE_GRAPHICAL_VT="${ALTITUDE_GRAPHICAL_VT:-2}" \
        nohup setsid /services/graphical.sh >>/var/log/service-graphical.log 2>&1 &
    fi
  else
    echo "[altitude] graphical requested but GNOME runtime is missing"
  fi
fi

echo "[altitude] native runtime ready"
EOF
chmod 755 "$PAYLOAD/etc/rc.altitude"

ln -s usr/lib "$PAYLOAD/lib"
ln -s usr/lib "$PAYLOAD/lib64"
ln -s ../bin "$PAYLOAD/usr/bin"
ln -s ../sbin "$PAYLOAD/usr/sbin"
chmod 1777 "$PAYLOAD/tmp"

{
  echo "Source: Altitude Linux"
  echo "Version: 0.1.0"
  echo "BDB: static C engine"
  echo "Init: systemd-ready rootfs; BusyBox fallback"
  echo "Compiler: $("$CC" --version | head -1)"
  echo "Debian-runtime-files: 0"
} > "$PAYLOAD/usr/share/altitude/sources/base-runtime.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/base-runtime/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-base-runtime-0.1.0-amd64.altpkg"
