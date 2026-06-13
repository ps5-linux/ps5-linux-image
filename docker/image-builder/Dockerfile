FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# System dependencies for distrobuilder and image creation
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates wget git make gcc libc6-dev build-essential \
    debootstrap rsync gpg dirmngr squashfs-tools \
    parted dosfstools e2fsprogs kmod \
    initramfs-tools fdisk gdisk udev kpartx \
    xz-utils bzip2 zstd \
    && rm -rf /var/lib/apt/lists/*

# Install Go (Ubuntu 24.04 only has 1.22, distrobuilder needs newer)
RUN wget -q https://go.dev/dl/go1.25.6.linux-amd64.tar.gz -O /tmp/go.tar.gz && \
    tar -C /usr/local -xzf /tmp/go.tar.gz && \
    rm /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:/root/go/bin:${PATH}"

# Build distrobuilder from source per upstream instructions
RUN mkdir -p /root/go/src/github.com/lxc/ && \
    cd /root/go/src/github.com/lxc/ && \
    git clone --depth 1 --branch v3.3.1 https://github.com/lxc/distrobuilder && \
    cd distrobuilder && \
    make && \
    cp /root/go/bin/distrobuilder /usr/local/bin/ && \
    rm -rf /root/go/src /root/go/pkg

# Fedora 41+ base images ship as OCI archives; distrobuilder's fedora-http
# downloader unpacks them with umoci/skopeo. Ubuntu's apt umoci (0.4.7) is
# built with an old Go that crashes under qemu on the self-hosted arm64 runner
# ("fatal error: lfstack.push invalid packing"), because the emulated amd64
# process inherits the host's 52-bit-VA high addresses. Build umoci from source
# with the Go toolchain installed above (>=1.21 packs high addresses correctly).
RUN apt-get update && apt-get install -y --no-install-recommends \
    skopeo \
    && rm -rf /var/lib/apt/lists/*
RUN go install github.com/opencontainers/umoci/cmd/umoci@v0.5.0 && \
    cp /root/go/bin/umoci /usr/local/bin/umoci && \
    rm -rf /root/go/pkg

WORKDIR /build

COPY docker/image-builder/entrypoint.sh /entrypoint.sh
COPY docker/image-builder/entrypoint-multi.sh /entrypoint-multi.sh
RUN chmod +x /entrypoint.sh /entrypoint-multi.sh

ENTRYPOINT ["/entrypoint.sh"]
