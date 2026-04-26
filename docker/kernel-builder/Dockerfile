FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential bc bison flex kmod cpio gawk \
    libdw-dev libelf-dev libssl-dev \
    python3 rsync dpkg-dev debhelper zstd \
    perl git xz-utils ccache \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/usr/lib/ccache:${PATH}"
ENV CCACHE_DIR=/ccache

WORKDIR /src

# Kernel source is bind-mounted at /src
# Build artifacts are staged to /out/staging

COPY docker/kernel-builder/build.sh /build.sh
RUN chmod +x /build.sh

CMD ["/build.sh"]
