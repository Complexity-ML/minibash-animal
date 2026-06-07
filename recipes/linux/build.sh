#!/usr/bin/env bash
# Build the complete Altitude Linux kernel from locked upstream source.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/linux}"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" linux)"
# A distro-generic kernel has several exceptionally memory-hungry translation
# units (notably modern GPU drivers). Keep the default forge build responsive;
# callers may still raise JOBS explicitly on larger builders.
JOBS="${JOBS:-4}"
VERSION=7.0.10
LOCALVERSION=-altitude
CROSS=x86_64-altitude-linux-gnu-
FORGE=/opt/altitude/forge
TOOLCHAIN=/opt/altitude/toolchain
BASE_CONFIG="$ROOT/recipes/linux/config/generic-x86_64.config"
RESUME="${ALTITUDE_RECIPE_RESUME:-0}"

if [ "$RESUME" != 1 ]; then
  rm -rf "$WORK"
  mkdir -p "$WORK/source"
  tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1
elif [ ! -f "$WORK/source/Makefile" ]; then
  echo "cannot resume: kernel source tree missing in $WORK/source" >&2
  exit 1
fi
rm -rf "$WORK/payload"
mkdir -p "$WORK/bin" "$WORK/payload/boot" \
  "$WORK/payload/usr/lib/modules" \
  "$WORK/payload/usr/share/altitude/sources" "$OUT"
[ -f "$BASE_CONFIG" ] || {
  echo "kernel base config missing: $BASE_CONFIG" >&2
  exit 1
}

# `bc` (kernel timeconst) from the Altitude BusyBox; invoked via a name=bc symlink.
BB="${ALTITUDE_BUSYBOX:-$FORGE/bin/busybox}"
[ -x "$BB" ] || BB=/var/tmp/altitude-forge/work/busybox/source/busybox
[ -x "$BB" ] || BB="$(command -v busybox || true)"
[ -n "$BB" ] && [ -x "$BB" ] || { echo "no busybox for bc" >&2; exit 1; }
ln -sf "$BB" "$WORK/bin/bc"
export PATH="$WORK/bin:$FORGE/bin:$TOOLCHAIN/bin:$PATH"

# objtool (host tool) links libelf from the forge. Make pkg-config + the host
# compiler/linker find it, and the resulting host binary find libelf.so.1 at
# runtime. elfutils may not ship a libelf.pc, so synthesize one.
if [ ! -f "$FORGE/lib/pkgconfig/libelf.pc" ]; then
  mkdir -p "$FORGE/lib/pkgconfig"
  cat > "$FORGE/lib/pkgconfig/libelf.pc" <<PC
prefix=$FORGE
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: libelf
Description: elfutils libelf (Altitude forge)
Version: 0.192
Libs: -L\${libdir} -lelf
Cflags: -I\${includedir}
PC
fi
# The kernel discovers libelf (objtool) / libcrypto (extract-cert) through its
# native pkg-config calls -- no global -I pollution (which would break the other
# host tools, e.g. relocs/mdp finding their own headers). pkgconf lives in the
# forge prefix, so it treats the forge's own include/lib as "system" and strips
# the -I/-L; point its system paths at /usr so it emits the forge flags instead.
# LD_LIBRARY_PATH lets the resulting host tools load libelf.so.1 / libcrypto.so.3.
export PKG_CONFIG_PATH="$FORGE/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export PKG_CONFIG_SYSTEM_INCLUDE_PATH=/usr/include
export PKG_CONFIG_SYSTEM_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:/usr/lib
export LD_LIBRARY_PATH="$FORGE/lib:${LD_LIBRARY_PATH:-}"

kmake() {
  make -C "$WORK/source" ARCH=x86 CROSS_COMPILE="$CROSS" HOSTCC=cc "$@"
}

# Start from the broad generic x86_64 configuration proven on the first target
# machine rather than defconfig. It intentionally supports far more hardware
# than that machine contains.
# Remove only Debian-owned identity/certificates and build metadata requiring
# tools not yet owned by the Altitude forge. Hardware, modules, objtool, ORC,
# IBT, CPU mitigations and module signing remain enabled.
cfg="$WORK/source/.config"
config="$WORK/source/scripts/config"
if [ "$RESUME" != 1 ]; then
  cp "$BASE_CONFIG" "$cfg"
  "$config" --file "$cfg" --set-str LOCALVERSION "$LOCALVERSION"
  "$config" --file "$cfg" -d LOCALVERSION_AUTO
  "$config" --file "$cfg" --set-str BUILD_SALT "Altitude Linux $VERSION"
  "$config" --file "$cfg" --set-str SYSTEM_TRUSTED_KEYS ""
  "$config" --file "$cfg" --set-str SYSTEM_REVOCATION_KEYS ""
  "$config" --file "$cfg" --set-str MODULE_SIG_KEY "certs/signing_key.pem"

  # Rust support in the imported config requires the exact rustc/bindgen pair
  # used by Debian. BTF requires pahole. Neither affects the runtime ABI or the
  # runtime drivers; enable them when those source-built forge recipes land.
  "$config" --file "$cfg" -d RUST
  "$config" --file "$cfg" -d DEBUG_INFO_BTF
  "$config" --file "$cfg" -d DEBUG_INFO_BTF_MODULES
  kmake olddefconfig
fi

for required in \
  CONFIG_MODULES=y \
  CONFIG_MODULE_SIG=y \
  CONFIG_OBJTOOL=y \
  CONFIG_UNWINDER_ORC=y \
  CONFIG_X86_KERNEL_IBT=y \
  CONFIG_IWLWIFI=m \
  CONFIG_IWLMVM=m \
  CONFIG_ATH9K=m \
  CONFIG_ATH10K=m \
  CONFIG_ATH11K=m \
  CONFIG_ATH12K=m \
  CONFIG_BRCMFMAC=m \
  CONFIG_MT76_CORE=m \
  CONFIG_RTW88=m \
  CONFIG_RTW89=m \
  CONFIG_DRM_AMDGPU=m \
  CONFIG_DRM_I915=m \
  CONFIG_DRM_NOUVEAU=m \
  CONFIG_R8169=m \
  CONFIG_E1000E=m \
  CONFIG_BLK_DEV_NVME=m \
  CONFIG_SATA_AHCI=m \
  CONFIG_USB_XHCI_HCD=m \
  CONFIG_USB_STORAGE=m \
  CONFIG_SND_HDA_INTEL=m \
  CONFIG_SND_USB_AUDIO=m \
  CONFIG_HID_GENERIC=m \
  CONFIG_USB_HID=m \
  CONFIG_BT=m \
  CONFIG_EXT4_FS=m; do
  grep -qx "$required" "$cfg" || {
    echo "required kernel option missing after olddefconfig: $required" >&2
    exit 1
  }
done

release="$(kmake -s kernelrelease)"
[ "$release" = "$VERSION$LOCALVERSION" ] || {
  echo "unexpected kernel release: $release" >&2
  exit 1
}

kmake -j"$JOBS" bzImage modules
kmake modules_install INSTALL_MOD_PATH="$WORK/payload" \
  INSTALL_MOD_STRIP=1

# modules_install follows the kernel convention /lib/modules. Altitude's
# merged-/usr root keeps the package canonical under /usr/lib/modules.
if [ -d "$WORK/payload/lib/modules/$release" ]; then
  mv "$WORK/payload/lib/modules/$release" \
    "$WORK/payload/usr/lib/modules/$release"
  rmdir "$WORK/payload/lib/modules" "$WORK/payload/lib"
fi
rm -f "$WORK/payload/usr/lib/modules/$release/build" \
  "$WORK/payload/usr/lib/modules/$release/source"
depmod -b "$WORK/payload" -m /usr/lib/modules "$release"

install -m644 "$WORK/source/arch/x86/boot/bzImage" \
  "$WORK/payload/boot/vmlinuz-$release"
install -m644 "$WORK/source/.config" \
  "$WORK/payload/boot/config-$release"
install -m644 "$WORK/source/System.map" \
  "$WORK/payload/boot/System.map-$release"

{
  echo "Source: linux"
  echo "Version: $VERSION"
  echo "Release: $release"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Config-SHA256: $(sha256sum "$cfg" | awk '{print $1}')"
  echo "Build: bzImage modules ARCH=x86 CROSS_COMPILE=$CROSS"
  echo "Compiler: $(${CROSS}gcc --version | head -1)"
  echo "Linker: $(${CROSS}ld --version | head -1)"
  echo "Host-compiler: $(cc --version | head -1)"
  echo "Rust: disabled until the Altitude rustc/bindgen forge stage"
  echo "BTF: disabled until the Altitude pahole forge stage"
} > "$WORK/payload/usr/share/altitude/sources/linux.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/linux/MANIFEST" "$WORK/payload" \
  "$OUT/altitude-kernel-$VERSION-amd64.altpkg"
