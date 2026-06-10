#!/bin/busybox sh
# minibash disk-root boot stub. Runs as PID 1 in the SMALL boot initramfs: load
# storage + ext4 drivers, mount the real root (root=), switch_root into it and
# exec the real /init (minit). The full rootfs lives on disk, not in RAM.

BB=/bin/busybox

$BB mkdir -p /proc /sys /dev /newroot
$BB mount -t proc proc /proc 2>/dev/null
$BB mount -t sysfs sysfs /sys 2>/dev/null
$BB mount -t devtmpfs devtmpfs /dev 2>/dev/null

log() { $BB echo "[boot] $*"; }

# On any failure, FREEZE with a diagnostic instead of exiting (which would make
# the kernel panic "attempted to kill init"). Shows what we actually detected.
fail() {
  log "FATAL: $*"
  log "---- /proc/partitions ----"; $BB cat /proc/partitions 2>/dev/null
  log "---- block devices ----"; $BB ls -l /dev/sd* /dev/vd* /dev/nvme* /dev/mmcblk* 2>/dev/null
  log "---- loaded modules ----"
  $BB cat /proc/modules 2>/dev/null | $BB awk '{print $1}' | $BB sort | $BB tr '\n' ' '
  $BB echo ""
  log "FROZEN (no reboot). Read the lines above to me."
  while true; do $BB sleep 3600; done
}

# Load storage controllers + fs drivers by name (depmod-resolved)...
log "loading storage/fs modules"
for m in libata libahci ahci ata_piix ata_generic sata_nv sata_via sata_sil \
         pata_amd pata_via pata_jmicron pata_sis pata_atiixp piix \
         sd_mod sr_mod nvme \
         virtio_pci virtio_blk virtio_scsi \
         ehci_hcd ehci_pci ohci_hcd uhci_hcd xhci_hcd xhci_pci usb_storage uas \
         crc32c_generic crc32c-intel libcrc32c crc16 mbcache jbd2 ext4 \
         vfat nls_cp437 nls_ascii nls_iso8859_1; do
  $BB modprobe "$m" 2>/dev/null
done
# ...and brute-force insmod everything we shipped, in case a name differs.
for ko in $($BB find /lib/modules -name '*.ko' 2>/dev/null); do
  $BB insmod "$ko" 2>/dev/null
done
$BB sleep 3

# Parse root= / rootfstype= from the kernel command line.
root=""
rootfstype="ext4"
rootflags="rw"
real_init="/init"
for arg in $($BB cat /proc/cmdline); do
  case "$arg" in
    root=*)        root="${arg#root=}" ;;
    rootfstype=*)  rootfstype="${arg#rootfstype=}" ;;
    ro)            rootflags="ro" ;;
    rw)            rootflags="rw" ;;
    altitude.init=systemd) real_init="/usr/lib/systemd/systemd" ;;
    altitude.init=busybox|minibash.init=busybox) real_init="/init" ;;
    altitude.real_init=*) real_init="${arg#altitude.real_init=}" ;;
  esac
done

case "$root" in
  UUID=*|LABEL=*) r="$($BB findfs "$root" 2>/dev/null)"; [ -n "$r" ] && root="$r" ;;
esac

log "root=$root type=$rootfstype ($rootflags)"

# Wait for the root device (slow USB/SATA enumeration); re-resolve LABEL each try.
i=0
while [ "$i" -lt 30 ]; do
  case "$root" in
    UUID=*|LABEL=*) r="$($BB findfs "$root" 2>/dev/null)"; [ -n "$r" ] && root="$r" ;;
  esac
  [ -b "$root" ] && break
  $BB sleep 1
  i=$((i + 1))
done

[ -b "$root" ] || fail "root device '$root' not found after 30s"

$BB mkdir -p /newroot
$BB mount -t "$rootfstype" -o "$rootflags" "$root" /newroot \
  || $BB mount "$root" /newroot \
  || fail "cannot mount $root ($rootfstype)"

for fs in proc sys dev; do
  $BB mkdir -p "/newroot/$fs"
  $BB mount --move "/$fs" "/newroot/$fs" 2>/dev/null
done

[ -x "/newroot$real_init" ] || fail "no executable $real_init on the new root ($root)"

log "switch_root -> $real_init"
exec $BB switch_root /newroot "$real_init"
fail "switch_root returned (this should never happen)"
