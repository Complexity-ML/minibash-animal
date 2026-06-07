#!/usr/bin/env bash
# Build the Altitude disk root filesystem. A disposable bootstrap forge provides
# third-party binaries; the delivered root is rebuilt only from signed Altitude
# packages and contains neither apt nor dpkg state.
#
# Unlike the RAM model (hand-copied files), this is a full Debian install on
# disk -> heavy desktops (GNOME) become a live `apt install` over SSH afterwards.
#
# Output: $ROOTFS_TGZ (the disk root) + (reuses build-disk.sh's boot initramfs).
set -euo pipefail

DISTRO_DIR="${DISTRO_DIR:-/work/minibash-linux}"
OUT_DIR="${OUT_DIR:-$DISTRO_DIR/out}"
ROOTFS_TGZ="${ROOTFS_TGZ:-$OUT_DIR/minibash-rootfs.tar.gz}"
CHROOT="${CHROOT:-/tmp/altitude-bootstrap-root}"
FINAL_ROOT="${FINAL_ROOT:-/tmp/altitude-package-root}"
SUITE="${SUITE:-trixie}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"

log() { printf '[altitude:rootfs] %s\n' "$*"; }
inchroot() { chroot "$CHROOT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive "$@"; }

# ---------------------------------------------------------------------------
# 1. Disposable bootstrap forge
# ---------------------------------------------------------------------------
log "debootstrap $SUITE -> $CHROOT"
rm -rf "$CHROOT"
mkdir -p "$CHROOT"
debootstrap --variant=minbase \
  --include=apt,ca-certificates,locales,kmod,util-linux,udev,dbus,bash,busybox,zstd,openssl \
  "$SUITE" "$CHROOT" "$MIRROR"

# bind mounts for apt inside the chroot
mount -t proc proc "$CHROOT/proc"
mount -t sysfs sysfs "$CHROOT/sys"
mount -o bind /dev "$CHROOT/dev"
mount -o bind /dev/pts "$CHROOT/dev/pts" 2>/dev/null || true
cleanup() {
  umount -l "$CHROOT/dev/pts" 2>/dev/null || true
  umount -l "$CHROOT/dev" 2>/dev/null || true
  umount -l "$CHROOT/sys" 2>/dev/null || true
  umount -l "$CHROOT/proc" 2>/dev/null || true
}
trap cleanup EXIT

# enable contrib/non-free for firmware
cat > "$CHROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main contrib non-free non-free-firmware
EOF

# Configure initramfs BEFORE installing linux-image-amd64. The kernel package
# generates /boot/initrd.img during install; doing this later forced a second
# expensive rebuild.
mkdir -p "$CHROOT/etc/initramfs-tools/conf.d"
{
  echo 'MODULES=list'
  echo 'COMPRESS=zstd'
} > "$CHROOT/etc/initramfs-tools/conf.d/zz-minibash"
cat > "$CHROOT/etc/initramfs-tools/modules" <<'EOF'
# USB boot media
xhci_hcd
xhci_pci
ehci_hcd
uhci_hcd
usb_storage
uas

# SATA / NVMe / SCSI disks
ahci
libahci
nvme
sd_mod
scsi_mod

# QEMU / virtio test boots
virtio
virtio_pci
virtio_blk
virtio_scsi

# Filesystems used by the image
ext4
mbcache
jbd2
vfat
fat
nls_cp437
nls_ascii
nls_utf8
EOF

# ---------------------------------------------------------------------------
# 2. Runtime packages (NOT GNOME yet — that goes in live over SSH)
# ---------------------------------------------------------------------------
log "installing base runtime (network, ssh, wifi, seat, gpu)"
inchroot apt-get update
inchroot apt-get install -y --no-install-recommends \
  linux-image-amd64 \
  network-manager iwd wpasupplicant iw rfkill \
  firmware-iwlwifi firmware-realtek firmware-atheros firmware-brcm80211 \
  wireless-regdb firmware-misc-nonfree \
  pciutils usbutils \
  dropbear-bin openssh-client \
  dbus elogind libpam-elogind \
  seatd \
  libgl1-mesa-dri libegl-mesa0 libgbm1 libegl1 libgles2 mesa-utils \
  fonts-dejavu-core fontconfig \
  sudo vim-tiny less iproute2 iputils-ping nano python3 openssl \
  procps psmisc \
  build-essential cargo rustc zstd rsync

# ---------------------------------------------------------------------------
# 2b. GNOME desktop (OPTIONAL). Off by default: the image stays lean and GNOME
#     is installed live over SSH once networking is up (`apt install gnome-*`).
#     Set INCLUDE_GNOME=1 to pre-bake it (real GNOME on a non-systemd box:
#     elogind provides logind, lightdm is the display manager, pam_elogind opens
#     the logind session mutter needs).
# ---------------------------------------------------------------------------
if [ "${INCLUDE_GNOME:-0}" = "1" ]; then
  log "installing GNOME desktop + lightdm (INCLUDE_GNOME=1)"
  # lightdm is our display manager; pre-seed it so installing gnome (which pulls
  # gdm3 as a recommend) doesn't grab the default.
  echo "/usr/sbin/lightdm" > "$CHROOT/etc/X11/default-display-manager" 2>/dev/null || true
  echo 'set shared/default-x-display-manager lightdm' | inchroot debconf-communicate >/dev/null 2>&1 || true
  inchroot apt-get install -y \
    gnome-session gnome-shell gnome-terminal gnome-control-center \
    gnome-settings-daemon gnome-backgrounds nautilus \
    lightdm lightdm-gtk-greeter \
    xorg xwayland dbus-x11 \
    adwaita-icon-theme fonts-cantarell \
    network-manager-gnome yad zenity \
    polkitd upower rtkit accountsservice \
    xdg-desktop-portal xdg-desktop-portal-gtk udisks2
  echo "/usr/sbin/lightdm" > "$CHROOT/etc/X11/default-display-manager"
  # allow passwordless autologin for the minibash user
  inchroot bash -c 'getent group nopasswdlogin >/dev/null || groupadd nopasswdlogin; usermod -aG nopasswdlogin,seat minibash 2>/dev/null || usermod -aG nopasswdlogin minibash'
  inchroot apt-get clean
else
  log "GNOME skipped (INCLUDE_GNOME=0) — install it live over SSH later"
fi

# minit applies minibash.keymap=fr by feeding a binary keymap to BusyBox
# loadkmap. Generate and wire that up in the forge.
mkdir -p "$CHROOT/etc/keymaps"
if command -v loadkeys >/dev/null 2>&1; then
  log "generating AZERTY console keymap"
  loadkeys -b fr > "$CHROOT/etc/keymaps/fr.bmap"
else
  log "loadkeys missing on builder; AZERTY keymap skipped"
fi
ln -sf /bin/busybox "$CHROOT/bin/loadkmap"

# locale
inchroot sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
inchroot locale-gen
echo 'LANG=en_US.UTF-8' > "$CHROOT/etc/default/locale"

# clean apt cache to shrink the rootfs
inchroot apt-get clean
rm -rf "$CHROOT"/var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 3. Altitude bootstrap overlay
# ---------------------------------------------------------------------------
log "overlaying Altitude bootstrap (init, bdb, services, package manager)"
# Altitude filesystem bits (services, tools, bdb seed, configs). We copy
# selectively so we don't clobber the forge's system users/PAM/etc.
for p in services bin/altitude bin/bdb bin/bdbql bin/bdbsh bin/bdbctl bin/bdbreg bin/bdbconf bin/bashsvc bin/login bin/passwd bin/desktop bin/desktop-install \
         bin/pkg bin/altpkg-build bin/altrepo bin/minibash-install bin/minibash-update bin/gpu bin/wifi \
         bin/netfix bin/wifidiag bin/minibash-services bin/minibash-desktop-warmup \
         etc/altitude etc/minibash etc/os-release etc/lsb-release etc/hostname etc/issue etc/shells etc/NetworkManager etc/iwd etc/lightdm etc/polkit-1 etc/sudoers.d \
         etc/modprobe.d/iwl.conf etc/fstab etc/xdg usr/share/applications usr/src/minibash; do
  if [ -e "$DISTRO_DIR/rootfs/$p" ]; then
    mkdir -p "$CHROOT/$(dirname "$p")"
    # -T: merge INTO an existing dir (e.g. /etc/NetworkManager) instead
    # of nesting it (which produced .../NetworkManager/NetworkManager/...).
    cp -aT "$DISTRO_DIR/rootfs/$p" "$CHROOT/$p"
  fi
done
cp -a "$DISTRO_DIR/rootfs/usr/share/udhcpc" "$CHROOT/usr/share/" 2>/dev/null || true

if [ -f "$CHROOT/usr/src/minibash/bdbc.c" ]; then
  log "building bdbc (C bdb engine)"
  inchroot gcc -O2 -Wall -Wextra -o /bin/bdbc /usr/src/minibash/bdbc.c
fi

# Build the first Altitude-owned packages, embed the public repository and
# install from it. The private signing key remains outside the image under out/.
log "building signed Altitude package repository"
ALTITUDE_PACKAGE_OUT="$OUT_DIR/packages" \
ALTITUDE_REPO_ROOT="$OUT_DIR/repository" \
  bash "$DISTRO_DIR/scripts/build-altitude-packages.sh"
mkdir -p "$CHROOT/var/lib/altitude/repository" "$CHROOT/etc/altitude/keys"
cp -a "$OUT_DIR/repository/INDEX" "$OUT_DIR/repository/INDEX.sig" \
  "$OUT_DIR/repository/packages" "$CHROOT/var/lib/altitude/repository/"
cp "$OUT_DIR/repository/repository.pem" \
  "$CHROOT/etc/altitude/keys/repository.pem"
log "installing Altitude-owned rootfs components from .altpkg"
for package in altitude-identity altitude-core altitude-services \
               altitude-access; do
  inchroot env BDB_PATH=/etc/minibash/bdb /bin/pkg install "$package"
done

# Desktop services in the native bdb. With GNOME pre-baked, enable graphical
# services. Without it, leave them down for a clean console boot.
desktop_services="udevd dbus elogind polkit upower rtkit accounts displayd portald udisksd graphical"
inchroot /bin/bdbc update services --where name=desktopd autostart=false desired=down >/dev/null || true
inchroot /bin/bdbc update services --where name=wpasupp autostart=false desired=down >/dev/null || true
if [ "${INCLUDE_GNOME:-0}" = "1" ]; then
  for svc in $desktop_services; do
    inchroot /bin/bdbc update services --where "name=$svc" autostart=true desired=up >/dev/null || true
  done
else
  for svc in $desktop_services; do
    inchroot /bin/bdbc update services --where "name=$svc" autostart=false desired=down >/dev/null || true
  done
fi
inchroot /bin/bdbc select services --where name=graphical || true

# build minit (Rust) and install as /init
log "building minit"
rm -f "$DISTRO_DIR/rust/minit/Cargo.lock"
( cd "$DISTRO_DIR/rust/minit" && cargo build --release )
cp "$DISTRO_DIR/rust/minit/target/release/minit" "$CHROOT/init"
chmod +x "$CHROOT/init"
# bdbboot helper (boot summary)
if [ -f "$DISTRO_DIR/rust/bdbboot/Cargo.toml" ]; then
  ( cd "$DISTRO_DIR/rust/bdbboot" && cargo build --release ) || true
  cp "$DISTRO_DIR/rust/bdbboot/target/release/bdbboot" "$CHROOT/bin/bdbboot" 2>/dev/null || true
fi
chmod +x "$CHROOT"/services/*.sh "$CHROOT"/bin/altitude "$CHROOT"/bin/bdb "$CHROOT"/bin/bdbql "$CHROOT"/bin/bdbsh \
         "$CHROOT"/bin/bdbctl "$CHROOT"/bin/bdbreg "$CHROOT"/bin/bdbconf "$CHROOT"/bin/bashsvc \
         "$CHROOT"/bin/pkg "$CHROOT"/bin/altpkg-build "$CHROOT"/bin/altrepo \
         "$CHROOT"/bin/login "$CHROOT"/bin/passwd "$CHROOT"/bin/desktop "$CHROOT"/bin/gpu \
         "$CHROOT"/bin/wifi "$CHROOT"/bin/netfix "$CHROOT"/bin/wifidiag \
         "$CHROOT"/bin/minibash-services "$CHROOT"/bin/minibash-desktop-warmup 2>/dev/null || true
chmod 440 "$CHROOT"/etc/sudoers.d/* 2>/dev/null || true

# the minibash desktop user (non-root, for sway/GNOME) + groups
inchroot bash -c 'id minibash >/dev/null 2>&1 || useradd -m -s /bin/bash -G video,input,render,audio,netdev minibash'
inchroot bash -c 'mkdir -p /home/minibash/.config /home/minibash/.local/share; chown -R minibash:minibash /home/minibash; chmod 755 /home/minibash'
inchroot bash -c 'rh="$(openssl passwd -6 root)"; mh="$(openssl passwd -6 minibash)"; printf "root:%s\nminibash:%s\n" "$rh" "$mh" | chpasswd -e'
# root + minibash SSH key
mkdir -p "$CHROOT/root/.ssh"
cp -a "$DISTRO_DIR/rootfs/root/.ssh/authorized_keys" "$CHROOT/root/.ssh/" 2>/dev/null || true
chmod 700 "$CHROOT/root/.ssh"; chmod 600 "$CHROOT/root/.ssh/authorized_keys" 2>/dev/null || true
# WiFi credentials (gitignored file) -> NetworkManager keyfile if present
if [ -f "$DISTRO_DIR/rootfs/etc/wpa_supplicant.conf" ]; then
  cp -a "$DISTRO_DIR/rootfs/etc/wpa_supplicant.conf" "$CHROOT/etc/wpa_supplicant.conf"
fi

# /etc/shells already shipped; ensure /bin/bash listed
grep -q '^/bin/bash' "$CHROOT/etc/shells" 2>/dev/null || echo /bin/bash >> "$CHROOT/etc/shells"

# ---------------------------------------------------------------------------
# 4. Capture the forge and reassemble a package-only Altitude root
# ---------------------------------------------------------------------------
log "capturing kernel, firmware and base userspace as Altitude packages"
bash "$DISTRO_DIR/scripts/capture-altitude-system.sh" \
  "$CHROOT" "$OUT_DIR/system-packages"

# A source-built Altitude kernel supersedes the bootstrap kernel snapshot.
# The package contains /boot/vmlinuz, System.map, config and all modules; the
# boot initramfs is generated later from that exact module tree.
if [ -n "${ALTITUDE_KERNEL_PACKAGE:-}" ]; then
  [ -f "$ALTITUDE_KERNEL_PACKAGE" ] || {
    echo "missing ALTITUDE_KERNEL_PACKAGE: $ALTITUDE_KERNEL_PACKAGE" >&2
    exit 1
  }
  rm -f "$OUT_DIR"/system-packages/altitude-kernel-*.altpkg
  cp "$ALTITUDE_KERNEL_PACKAGE" "$OUT_DIR/system-packages/"
  log "using source-built kernel package: $ALTITUDE_KERNEL_PACKAGE"
fi

for package in "$OUT_DIR"/system-packages/*.altpkg; do
  ALTITUDE_REPO_ROOT="$OUT_DIR/repository" \
    bash "$DISTRO_DIR/rootfs/bin/altrepo" add "$package"
done
ALTITUDE_REPO_ROOT="$OUT_DIR/repository" \
  bash "$DISTRO_DIR/rootfs/bin/altrepo" verify

log "assembling clean rootfs exclusively from signed Altitude packages"
bash "$DISTRO_DIR/scripts/assemble-altitude-rootfs.sh" \
  "$OUT_DIR/repository" "$FINAL_ROOT" \
  altitude-base altitude-kernel altitude-firmware \
  altitude-identity altitude-core altitude-services altitude-access
mkdir -p "$FINAL_ROOT"/{dev,proc,run,sys,tmp}
chmod 1777 "$FINAL_ROOT/tmp"
mkdir -p "$FINAL_ROOT/var/lib/altitude/repository" \
  "$FINAL_ROOT/etc/altitude/keys"
cp -a "$OUT_DIR/repository/INDEX" "$OUT_DIR/repository/INDEX.sig" \
  "$OUT_DIR/repository/packages" \
  "$FINAL_ROOT/var/lib/altitude/repository/"
cp "$OUT_DIR/repository/repository.pem" \
  "$FINAL_ROOT/etc/altitude/keys/repository.pem"

# Record every package in the seed BDB. The native engine is already present
# in altitude-base, so this does not require apt or dpkg in the final root.
for package in altitude-base altitude-kernel altitude-firmware \
               altitude-identity altitude-core altitude-services \
               altitude-access; do
  metadata="$(awk -v wanted="$package" '
    BEGIN { RS=""; FS="\n" }
    {
      name=""
      for (i=1; i<=NF; i++)
        if ($i ~ /^Package: /) name=substr($i,10)
      if (name == wanted) print $0
    }
  ' "$OUT_DIR/repository/INDEX")"
  version="$(printf '%s\n' "$metadata" | sed -n 's/^Version: *//p')"
  filename="$(printf '%s\n' "$metadata" | sed -n 's/^Filename: *//p')"
  checksum="$(printf '%s\n' "$metadata" | sed -n 's/^SHA256: *//p')"
  description="$(printf '%s\n' "$metadata" | sed -n 's/^Description: *//p')"
  if chroot "$FINAL_ROOT" /usr/bin/env BDB_PATH=/etc/minibash/bdb \
     /bin/bdbc select packages --where "name=$package" |
       tail -n +2 | grep -q .; then
    chroot "$FINAL_ROOT" /usr/bin/env BDB_PATH=/etc/minibash/bdb \
      /bin/bdbc update packages --where "name=$package" \
      version="$version" state=installed \
      source="file:///var/lib/altitude/repository/$filename" \
      checksum="$checksum" description="$description" >/dev/null
  else
    chroot "$FINAL_ROOT" /usr/bin/env BDB_PATH=/etc/minibash/bdb \
      /bin/bdbc insert packages name="$package" \
      version="$version" state=installed \
      source="file:///var/lib/altitude/repository/$filename" \
      checksum="$checksum" description="$description" >/dev/null
  fi
done
chroot "$FINAL_ROOT" /usr/bin/env BDB_PATH=/etc/minibash/bdb \
  /bin/pkg verify

# ---------------------------------------------------------------------------
# 5. Pack the package-assembled rootfs tarball
# ---------------------------------------------------------------------------
cleanup
trap - EXIT
log "packing disk rootfs tarball -> $ROOTFS_TGZ"
tar --numeric-owner --owner=0 --group=0 -czf "$ROOTFS_TGZ" -C "$FINAL_ROOT" .
ls -lh "$ROOTFS_TGZ"
log "done. boot initramfs: run build-disk.sh with SKIP_ROOTFS to (re)build it, then build-disk-image.sh"
