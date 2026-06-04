FROM --platform=linux/amd64 debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN sed -i 's/Components: main/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    bc \
    binutils \
    bison \
    bsdextrautils \
    build-essential \
    busybox-static \
    ca-certificates \
    console-data \
    cpio \
    dosfstools \
    dropbear-bin \
    dwarves \
    fdisk \
    file \
    findutils \
    flex \
    firmware-misc-nonfree \
    firmware-iwlwifi \
    wireless-regdb \
    wpasupplicant \
    iw \
    rfkill \
    fontconfig \
    fonts-dejavu-core \
    foot \
    gawk \
    grub-efi-amd64-bin \
    gzip \
    kbd \
    kmod \
    libelf-dev \
    locales \
    libgl1-mesa-dri \
    libva2 \
    libva-drm2 \
    mesa-va-drivers \
    libssl-dev \
    make \
    mtools \
    ovmf \
    qemu-system-x86 \
    rsync \
    cargo \
    extlinux \
    isolinux \
    rustc \
    syslinux-common \
    sed \
    seatd \
    sway \
    udev \
    util-linux \
    weston \
    xorriso \
    xz-utils \
  && rm -rf /var/lib/apt/lists/*

# foot (and any terminal) refuses to start without a UTF-8 locale; generate a
# real UTF-8 locale so /usr/lib/locale/locale-archive exists for the rootfs.
RUN sed -i 's/^# *\(en_US.UTF-8\|fr_FR.UTF-8\)/\1/' /etc/locale.gen && locale-gen

WORKDIR /work/minibash-linux

CMD ["bash", "/work/minibash-linux/build.sh"]
