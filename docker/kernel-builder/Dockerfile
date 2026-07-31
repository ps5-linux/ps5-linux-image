FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

RUN dpkg --add-architecture amd64 \
    && apt-get update && apt-get install -y --no-install-recommends \
    build-essential bc bison dwarves flex kmod cpio gawk pkg-config \
    libdw-dev libelf-dev libssl-dev zlib1g-dev \
    libdw-dev:amd64 libelf-dev:amd64 zlib1g-dev:amd64 \
    python3 rsync dpkg-dev debhelper zstd \
    perl git ca-certificates xz-utils ccache \
    crossbuild-essential-amd64 \
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
