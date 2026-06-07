#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/base-runtime}"
TOOLCHAIN=/opt/altitude/toolchain
CC="$TOOLCHAIN/bin/x86_64-altitude-linux-gnu-gcc"
BUSYBOX_WORK="${ALTITUDE_BUSYBOX_WORK:-$ROOT/out/source-work/busybox}"
BASH_WORK="${ALTITUDE_BASH_WORK:-$ROOT/out/source-work/bash}"
BUSYBOX="$BUSYBOX_WORK/payload/usr/libexec/altitude/busybox"
BASH="$BASH_WORK/payload/bin/bash"
PAYLOAD="$WORK/payload"

for input in "$CC" "$BUSYBOX" "$BASH" \
  "$ROOT/rootfs/usr/src/minibash/bdbc.c"; do
  [ -e "$input" ] || {
    echo "base-runtime: missing build input: $input" >&2
    exit 1
  }
done

rm -rf "$WORK"
mkdir -p "$PAYLOAD"/{bin,sbin,etc,proc,sys,dev,run,tmp,root,home,var/log} \
  "$PAYLOAD/usr/lib/modules" "$PAYLOAD/usr/share/altitude/sources"

install -m755 "$BUSYBOX" "$PAYLOAD/bin/busybox"
install -m755 "$BASH" "$PAYLOAD/bin/bash"
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
ln -s sbin/init "$PAYLOAD/init"

"$CC" -O2 -static -Wall -Wextra \
  -o "$PAYLOAD/bin/bdbc" "$ROOT/rootfs/usr/src/minibash/bdbc.c"
ldd_output="$(ldd "$PAYLOAD/bin/bdbc" 2>&1 || true)"
grep -Eq 'not a dynamic executable|statically linked' <<< "$ldd_output"

for path in \
  bin/altitude bin/bdb bin/bdbql bin/bdbsh bin/bdbctl bin/bdbreg bin/bdbconf \
  bin/bashsvc bin/login bin/passwd bin/pkg bin/altpkg-build bin/altrepo \
  bin/minibash-services \
  etc/altitude etc/minibash etc/os-release etc/lsb-release etc/hostname \
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
hostname altitude
echo /sbin/modprobe > /proc/sys/kernel/modprobe 2>/dev/null || true
if [ ! -f /var/bdb/tables/services/data.bdb ]; then
  cp -a /etc/minibash/bdb/. /var/bdb/
fi
echo "[altitude] native runtime ready"
EOF
chmod 755 "$PAYLOAD/etc/rc.altitude"

ln -s usr/lib "$PAYLOAD/lib"
ln -s ../bin "$PAYLOAD/usr/bin"
ln -s ../sbin "$PAYLOAD/usr/sbin"
chmod 1777 "$PAYLOAD/tmp"

{
  echo "Source: Altitude Linux"
  echo "Version: 0.1.0"
  echo "BDB: static C engine"
  echo "Init: BusyBox init"
  echo "Compiler: $("$CC" --version | head -1)"
  echo "Debian-runtime-files: 0"
} > "$PAYLOAD/usr/share/altitude/sources/base-runtime.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/base-runtime/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-base-runtime-0.1.0-amd64.altpkg"
