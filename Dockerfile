FROM --platform=linux/amd64 debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    bc \
    binutils \
    bison \
    bsdextrautils \
    build-essential \
    busybox-static \
    ca-certificates \
    cpio \
    dosfstools \
    dropbear-bin \
    dwarves \
    fdisk \
    file \
    findutils \
    flex \
    foot \
    gawk \
    grub-efi-amd64-bin \
    gzip \
    kmod \
    libelf-dev \
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
    util-linux \
    weston \
    xorriso \
    xz-utils \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /work/minibash-linux

CMD ["bash", "/work/minibash-linux/build.sh"]
