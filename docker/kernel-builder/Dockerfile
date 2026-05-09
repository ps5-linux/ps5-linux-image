FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential bc bison dwarves flex kmod cpio gawk \
    libdw-dev libelf-dev libssl-dev \
    python3 rsync dpkg-dev debhelper zstd \
    perl git xz-utils ccache \
    gcc-x86-64-linux-gnu binutils-x86-64-linux-gnu libc6-dev-amd64-cross \
    && rm -rf /var/lib/apt/lists/*

ENV ARCH=x86_64
ENV CROSS_COMPILE=x86_64-linux-gnu-
ENV PATH="/usr/lib/ccache:${PATH}"
ENV CCACHE_DIR=/ccache

WORKDIR /src

# Kernel source is bind-mounted at /src
# Build artifacts are staged to /out/staging

COPY docker/kernel-builder/build.sh /build.sh
COPY docker/kernel-builder/package-deb.sh /package-deb.sh
RUN chmod +x /build.sh /package-deb.sh

CMD ["/build.sh"]
