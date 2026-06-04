#!/usr/bin/env bash
set -euo pipefail

DISTRO_DIR="${DISTRO_DIR:-/work/minibash-linux}"
KERNEL_TAR="${KERNEL_TAR:-/work/linux-kernel-src/linux-7.0.10.tar.xz}"
KERNEL_DIR="${KERNEL_DIR:-/tmp/minibash-linux-kernel/linux-7.0.10}"
OUT_DIR="${OUT_DIR:-$DISTRO_DIR/out}"
ROOTFS_SRC="$DISTRO_DIR/rootfs"
ROOTFS_WORK="${ROOTFS_WORK:-/tmp/minibash-linux-rootfs}"
INITRAMFS_IMG="${INITRAMFS_IMG:-$OUT_DIR/minibash-linux-initramfs.cpio.gz}"
KERNEL_MODULES_DIR="${KERNEL_MODULES_DIR:-$OUT_DIR/debian-modules}"
REUSE_KERNEL="${REUSE_KERNEL:-/work/linux-bash-hybrid/out/bzImage}"
BUILD_KERNEL="${BUILD_KERNEL:-0}"
INCLUDE_DESKTOP="${INCLUDE_DESKTOP:-0}"

log() {
  printf '[minibash:build] %s\n' "$*"
}

copy_with_libs() {
  local bin="$1"
  local dest="$ROOTFS_WORK$bin"
  mkdir -p "$(dirname "$dest")"
  cp -L "$bin" "$dest"

  ldd "$bin" | awk '
    /=> \// { print $3 }
    /^\// { print $1 }
    /ld-linux/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^\//) print $i
      }
    }
  ' | sort -u | while read -r lib; do
    [ -n "$lib" ] || continue
    mkdir -p "$ROOTFS_WORK$(dirname "$lib")"
    cp -L "$lib" "$ROOTFS_WORK$lib"
  done
}

copy_cmd_with_libs() {
  local cmd="$1"
  local path
  path="$(type -P "$cmd" || true)"
  if [ -z "$path" ]; then
    log "using shell builtin: $cmd"
    return 0
  fi
  copy_with_libs "$path"
}

copy_deb_package_files() {
  local pkg="$1"
  if ! dpkg-query -W "$pkg" >/dev/null 2>&1; then
    log "optional package missing: $pkg"
    return 0
  fi
  log "copying package files: $pkg"
  dpkg-query -L "$pkg" | while read -r src; do
    [ -e "$src" ] || continue
    [ "$src" = "/" ] && continue
    case "$src" in
      /usr/share/doc/*|/usr/share/man/*|/usr/share/lintian/*) continue ;;
    esac
    if [ -d "$src" ] && [ ! -L "$src" ]; then
      mkdir -p "$ROOTFS_WORK$src"
    else
      mkdir -p "$ROOTFS_WORK$(dirname "$src")"
      cp -a "$src" "$ROOTFS_WORK$src"
    fi
  done
}

copy_libs_for_binary() {
  local bin="$1"
  ldd "$bin" | awk '
    /=> \// { print $3 }
    /^\// { print $1 }
    /ld-linux/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^\//) print $i
      }
    }
  ' | sort -u | while read -r lib; do
    [ -n "$lib" ] || continue
    mkdir -p "$ROOTFS_WORK$(dirname "$lib")"
    cp -L "$lib" "$ROOTFS_WORK$lib"
  done
}

install_busybox() {
  local busybox
  busybox="$(type -P busybox)"
  mkdir -p "$ROOTFS_WORK/bin"
  cp -L "$busybox" "$ROOTFS_WORK/bin/busybox"
  chmod +x "$ROOTFS_WORK/bin/busybox"
  # NB: bdb (the Bash DB) shells out to mv and rmdir on its write path; neither
  # is copied as a real coreutil, so they MUST be provided here or every
  # `bdb update/insert/delete` (i.e. every `bashsvc start/stop`) fails.
  for applet in sh ls ps kill dmesg true false echo pwd clear rm mv rmdir \
                nc ip ifconfig route hostname cat date ash vi umount \
                free uptime top df whoami id groups cut wc syslogd logger \
                mke2fs sync tar sha256sum chmod chown ln dd loadkmap chvt openvt; do
    ln -sf /bin/busybox "$ROOTFS_WORK/bin/$applet"
  done
}

install_keymaps() {
  mkdir -p "$ROOTFS_WORK/etc/keymaps"
  if type -P loadkeys >/dev/null 2>&1; then
    log "generating AZERTY console keymap"
    loadkeys -b fr > "$ROOTFS_WORK/etc/keymaps/fr.bmap"
  else
    log "loadkeys missing on builder; AZERTY keymap skipped"
  fi
}

build_rust_helper() {
  log "building Rust boot helper"
  rm -f "$DISTRO_DIR/rust/bdbboot/Cargo.lock"
  cargo build --manifest-path "$DISTRO_DIR/rust/bdbboot/Cargo.toml" --release
  cp "$DISTRO_DIR/rust/bdbboot/target/release/bdbboot" "$ROOTFS_WORK/bin/bdbboot"
  copy_libs_for_binary "$DISTRO_DIR/rust/bdbboot/target/release/bdbboot"
}

build_minit() {
  log "building Rust PID 1 (minit)"
  rm -f "$DISTRO_DIR/rust/minit/Cargo.lock"
  cargo build --manifest-path "$DISTRO_DIR/rust/minit/Cargo.toml" --release
  # minit is the kernel's init=/init
  cp "$DISTRO_DIR/rust/minit/target/release/minit" "$ROOTFS_WORK/init"
  copy_libs_for_binary "$DISTRO_DIR/rust/minit/target/release/minit"
}

prepare_rootfs() {
  log "preparing rootfs"
  rm -rf "$ROOTFS_WORK"
  mkdir -p "$ROOTFS_WORK"
  rsync -a "$ROOTFS_SRC"/ "$ROOTFS_WORK"/

  mkdir -p "$ROOTFS_WORK"/{bin,dev,etc,proc,run,sbin,services,sys,tmp,usr/bin,usr/sbin,var/log,var/bdb}
  mknod -m 600 "$ROOTFS_WORK/dev/console" c 5 1
  mknod -m 666 "$ROOTFS_WORK/dev/null" c 1 3
  mknod -m 666 "$ROOTFS_WORK/dev/tty" c 5 0

  install_busybox
  install_keymaps
  copy_cmd_with_libs bash
  copy_cmd_with_libs awk
  copy_cmd_with_libs base64
  copy_cmd_with_libs basename
  copy_cmd_with_libs cat
  copy_cmd_with_libs column
  copy_cmd_with_libs cp
  copy_cmd_with_libs dirname
  copy_cmd_with_libs env
  copy_cmd_with_libs grep
  copy_cmd_with_libs head
  copy_cmd_with_libs mkdir
  copy_cmd_with_libs mktemp
  copy_cmd_with_libs mount
  copy_cmd_with_libs sed
  copy_cmd_with_libs sleep
  copy_cmd_with_libs sort
  copy_cmd_with_libs tail
  copy_cmd_with_libs tr
  copy_cmd_with_libs uniq
  copy_cmd_with_libs dropbear
  copy_cmd_with_libs dropbearkey
  copy_cmd_with_libs wpa_supplicant
  copy_cmd_with_libs wpa_cli
  copy_cmd_with_libs iw
  copy_cmd_with_libs rfkill
  # WiFi firmware + regulatory db (for iwlwifi); always shipped so SSH-over-WiFi
  # works on console boots too, not just the desktop.
  copy_deb_package_files firmware-iwlwifi
  copy_deb_package_files wireless-regdb
  copy_cmd_with_libs extlinux
  copy_cmd_with_libs syslinux
  copy_cmd_with_libs insmod
  copy_cmd_with_libs modprobe
  if [ "$INCLUDE_DESKTOP" = "1" ]; then
    log "including desktop runtime"
    copy_cmd_with_libs weston
    copy_cmd_with_libs foot
    copy_cmd_with_libs weston-terminal
    copy_cmd_with_libs sway
    copy_cmd_with_libs seatd
    copy_cmd_with_libs setpriv

    for pkg in \
      weston libweston-10-0 \
      foot foot-terminfo \
      libwayland-server0 libwayland-client0 libwayland-cursor0 libwayland-egl1 \
      libinput10 libseat1 libxkbcommon0 libpixman-1-0 \
      xkb-data \
      libdrm2 libdrm-intel1 libdrm-amdgpu1 libdrm-nouveau2 libdrm-radeon1 \
      libgbm1 libegl1 libgles2 libgl1 mesa-utils \
      libgl1-mesa-dri libva2 libva-drm2 mesa-va-drivers \
      libegl-mesa0 libglx-mesa0 libglapi-mesa libgbm1 \
      udev libudev1 \
      seatd sway libseat1 libwlroots10 \
      fontconfig fonts-dejavu-core; do
      copy_deb_package_files "$pkg"
    done

    # The generated UTF-8 locale archive (from locale-gen in the Docker image) is
    # not part of any package, so copy it explicitly: foot needs a real UTF-8
    # locale or it aborts with "set locale failed".
    if [ -f /usr/lib/locale/locale-archive ]; then
      mkdir -p "$ROOTFS_WORK/usr/lib/locale"
      cp -a /usr/lib/locale/locale-archive "$ROOTFS_WORK/usr/lib/locale/"
    fi

    # Mesa DRI/VA drivers AND weston backends/shells are loaded via dlopen(), so
    # ldd on the weston binary never sees them and their NEEDED libs (libLLVM,
    # libzstd, libsensors, libdrm, libva for the DRI drivers; libdbus-1 for the
    # drm-backend/logind launcher; etc.) are otherwise missing. Resolve the deps
    # of every dlopen'd module so the runtime closure is complete.
    for drvdir in \
      "$ROOTFS_WORK"/usr/lib/*/dri \
      "$ROOTFS_WORK"/usr/lib/dri \
      "$ROOTFS_WORK"/usr/lib/*/libweston-* \
      "$ROOTFS_WORK"/usr/lib/*/weston \
      "$ROOTFS_WORK"/usr/lib/libweston-* \
      "$ROOTFS_WORK"/usr/lib/weston; do
      [ -d "$drvdir" ] || continue
      for drv in "$drvdir"/*.so*; do
        [ -e "$drv" ] || continue
        copy_libs_for_binary "$drv"
      done
    done

    # GLVND vendor implementations are dlopen'd via egl_vendor.d / glx, so their
    # NEEDED libs (libxcb-*, libX11-xcb, libwayland-*, libexpat, ...) are invisible
    # to ldd on weston. Resolve them so EGL can actually initialise a display.
    for vendor in \
      "$ROOTFS_WORK"/usr/lib/*/libEGL_mesa.so* \
      "$ROOTFS_WORK"/usr/lib/*/libGLX_mesa.so* \
      "$ROOTFS_WORK"/usr/lib/libEGL_mesa.so* \
      "$ROOTFS_WORK"/usr/lib/libGLX_mesa.so*; do
      [ -e "$vendor" ] || continue
      copy_libs_for_binary "$vendor"
    done

    # udevd/udevadm provide the device tags (ID_INPUT/ID_SEAT) that libinput and
    # libseat need; copy_deb_package_files brought the binaries but not their
    # NEEDED libs (libkmod, libacl, libblkid, libcap, ...). Resolve them.
    for ubin in \
      "$ROOTFS_WORK"/usr/lib/systemd/systemd-udevd \
      "$ROOTFS_WORK"/lib/systemd/systemd-udevd \
      "$ROOTFS_WORK"/usr/bin/udevadm \
      "$ROOTFS_WORK"/bin/udevadm; do
      [ -e "$ubin" ] || continue
      copy_libs_for_binary "$ubin"
    done
  else
    log "desktop runtime skipped (INCLUDE_DESKTOP=0)"
  fi

  ln -sf /usr/bin/awk "$ROOTFS_WORK/bin/awk"
  ln -sf /usr/bin/base64 "$ROOTFS_WORK/bin/base64"
  ln -sf /usr/bin/column "$ROOTFS_WORK/bin/column"
  ln -sf /usr/bin/mount "$ROOTFS_WORK/bin/mount"
  ln -sf /usr/bin/tail "$ROOTFS_WORK/bin/tail"
  # minit (PID 1) and the service scripts call these by absolute /bin path,
  # but on the Debian builder they live under /usr/bin.
  ln -sf /usr/bin/bash "$ROOTFS_WORK/bin/bash"
  ln -sf /usr/bin/cp "$ROOTFS_WORK/bin/cp"
  if [ -x "$ROOTFS_WORK/usr/sbin/dropbear" ]; then
    ln -sf /usr/sbin/dropbear "$ROOTFS_WORK/bin/dropbear"
  fi
  if [ -x "$ROOTFS_WORK/usr/bin/dropbearkey" ]; then
    ln -sf /usr/bin/dropbearkey "$ROOTFS_WORK/bin/dropbearkey"
  fi
  if [ -x "$ROOTFS_WORK/usr/bin/extlinux" ]; then
    ln -sf /usr/bin/extlinux "$ROOTFS_WORK/bin/extlinux"
  fi
  if [ -x "$ROOTFS_WORK/usr/bin/syslinux" ]; then
    ln -sf /usr/bin/syslinux "$ROOTFS_WORK/bin/syslinux"
  fi
  if [ -x "$ROOTFS_WORK/usr/sbin/insmod" ]; then
    ln -sf /usr/sbin/insmod "$ROOTFS_WORK/bin/insmod"
  fi
  if [ -x "$ROOTFS_WORK/usr/sbin/modprobe" ]; then
    ln -sf /usr/sbin/modprobe "$ROOTFS_WORK/bin/modprobe"
    # The kernel's request_module() (e.g. iwlwifi auto-loading its iwlmvm/iwldvm
    # opmode) execs /sbin/modprobe by default; without it, auto-loaded modules
    # silently never load (→ driver present but no wlan0).
    mkdir -p "$ROOTFS_WORK/sbin"
    ln -sf /usr/sbin/modprobe "$ROOTFS_WORK/sbin/modprobe"
  fi
  if [ -x "$ROOTFS_WORK/usr/bin/weston" ]; then
    ln -sf /usr/bin/weston "$ROOTFS_WORK/bin/weston"
  fi
  if [ -x "$ROOTFS_WORK/usr/bin/foot" ]; then
    ln -sf /usr/bin/foot "$ROOTFS_WORK/bin/foot"
  fi
  if [ -x "$ROOTFS_WORK/usr/bin/weston-terminal" ]; then
    ln -sf /usr/bin/weston-terminal "$ROOTFS_WORK/bin/weston-terminal"
  fi
  for mbr in /usr/lib/SYSLINUX/mbr.bin /usr/lib/syslinux/mbr/mbr.bin /usr/share/syslinux/mbr.bin; do
    if [ -f "$mbr" ]; then
      mkdir -p "$ROOTFS_WORK/usr/lib/SYSLINUX"
      cp "$mbr" "$ROOTFS_WORK/usr/lib/SYSLINUX/mbr.bin"
      break
    fi
  done

  if [ -d "$KERNEL_MODULES_DIR/lib/modules" ]; then
    log "copying kernel modules from $KERNEL_MODULES_DIR"
    mkdir -p "$ROOTFS_WORK/lib/modules"
    cp -a "$KERNEL_MODULES_DIR/lib/modules/." "$ROOTFS_WORK/lib/modules/"
    copy_deb_package_files firmware-misc-nonfree
    for version_dir in "$ROOTFS_WORK"/lib/modules/*; do
      [ -d "$version_dir" ] || continue
      version="$(basename "$version_dir")"
      log "indexing kernel modules for $version"
      depmod -b "$ROOTFS_WORK" "$version"
    done
  else
    log "kernel modules skipped (missing $KERNEL_MODULES_DIR)"
  fi

  build_rust_helper
  build_minit
  chmod +x "$ROOTFS_WORK/init" "$ROOTFS_WORK/bin/bdb" "$ROOTFS_WORK/bin/bashsvc" \
           "$ROOTFS_WORK/bin/login" "$ROOTFS_WORK/bin/minibash-install" \
           "$ROOTFS_WORK/bin/pkg" "$ROOTFS_WORK/bin/minibash-update" \
           "$ROOTFS_WORK/bin/desktop" "$ROOTFS_WORK/bin/desktop-install" \
           "$ROOTFS_WORK"/services/*.sh
  # diagnostics + helpers that ship as plain (non-exec) files in the repo
  chmod +x "$ROOTFS_WORK/bin/gpu" "$ROOTFS_WORK/bin/wifi" \
           "$ROOTFS_WORK/usr/share/udhcpc/default.script" 2>/dev/null || true
  # dropbear is strict about key file permissions
  if [ -d "$ROOTFS_WORK/root/.ssh" ]; then
    chmod 700 "$ROOTFS_WORK/root/.ssh"
    chmod 600 "$ROOTFS_WORK/root/.ssh/authorized_keys" 2>/dev/null || true
  fi
}

pack_initramfs() {
  log "packing initramfs"
  mkdir -p "$OUT_DIR"
  (cd "$ROOTFS_WORK" && find . -print0 | cpio --null -ov --format=newc | gzip -9 > "$INITRAMFS_IMG")
  log "initramfs: $INITRAMFS_IMG"
}

build_kernel() {
  if [ "$BUILD_KERNEL" != "1" ]; then
    # Prefer the external prebuilt kernel, but fall back to a repo-local cache
    # so the build stays self-contained if that external tree disappears.
    if [ ! -f "$REUSE_KERNEL" ] && [ -f "$DISTRO_DIR/kernel/bzImage" ]; then
      REUSE_KERNEL="$DISTRO_DIR/kernel/bzImage"
      log "external kernel missing; using cached $REUSE_KERNEL"
    fi
    if [ ! -f "$REUSE_KERNEL" ]; then
      echo "missing reusable kernel: $REUSE_KERNEL" >&2
      echo "set BUILD_KERNEL=1 or REUSE_KERNEL=/path/to/bzImage" >&2
      return 1
    fi
    if [ "$REUSE_KERNEL" != "$OUT_DIR/bzImage" ]; then
      cp "$REUSE_KERNEL" "$OUT_DIR/bzImage"
    fi
    log "kernel reused: $OUT_DIR/bzImage"
    return
  fi

  log "extracting Linux source"
  rm -rf /tmp/minibash-linux-kernel
  mkdir -p /tmp/minibash-linux-kernel
  tar -xf "$KERNEL_TAR" -C /tmp/minibash-linux-kernel

  log "configuring Linux kernel"
  cd "$KERNEL_DIR"
  make mrproper
  make x86_64_defconfig
  scripts/config --enable BLK_DEV_INITRD
  scripts/config --enable DEVTMPFS
  scripts/config --enable DEVTMPFS_MOUNT
  scripts/config --enable PROC_FS
  scripts/config --enable SYSFS
  scripts/config --enable TMPFS
  scripts/config --enable TTY
  scripts/config --enable VT
  scripts/config --enable VT_CONSOLE
  scripts/config --enable HW_CONSOLE
  scripts/config --enable VGA_CONSOLE
  scripts/config --enable DUMMY_CONSOLE
  scripts/config --enable UNIX98_PTYS
  scripts/config --enable EFI
  scripts/config --enable EFI_STUB
  scripts/config --enable EFI_PARTITION
  scripts/config --enable SYSFB
  scripts/config --enable SYSFB_SIMPLEFB
  scripts/config --enable FB
  scripts/config --enable FB_EFI
  scripts/config --enable FRAMEBUFFER_CONSOLE
  scripts/config --enable SERIAL_8250
  scripts/config --enable SERIAL_8250_CONSOLE
  # The live USB targets a reliable text console first. Native DRM/KMS drivers
  # can blank some laptop panels during early boot, so keep EFI framebuffer only.
  scripts/config --disable DRM
  scripts/config --disable DRM_SIMPLEDRM
  scripts/config --disable DRM_I915
  scripts/config --disable DRM_NOUVEAU
  scripts/config --disable DRM_AMDGPU
  scripts/config --disable DRM_RADEON
  scripts/config --disable DRM_VIRTIO_GPU
  scripts/config --disable DEBUG_INFO
  scripts/config --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
  make olddefconfig

  log "building Linux kernel"
  make -j"$(nproc)" bzImage
  cp arch/x86/boot/bzImage "$OUT_DIR/bzImage"
}

write_runner() {
  log "writing qemu runner"
  sed "s#__OUT_DIR__#$OUT_DIR#g" "$DISTRO_DIR/scripts/run-qemu.template.sh" > "$OUT_DIR/run-qemu.sh"
  chmod +x "$OUT_DIR/run-qemu.sh"
}

main() {
  mkdir -p "$OUT_DIR"
  prepare_rootfs
  pack_initramfs
  build_kernel
  write_runner
}

main "$@"
