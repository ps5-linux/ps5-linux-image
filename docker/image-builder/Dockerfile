# Go tools are built here: Ubuntu's Go 1.22 builds of skopeo and umoci crash
# under qemu on the arm64 runner.

ARG GO_VERSION=1.25.6
ARG DISTROBUILDER_VERSION=v3.3.1
ARG SKOPEO_VERSION=v1.22.4
ARG UMOCI_VERSION=v0.5.0

FROM golang:${GO_VERSION}-bookworm AS tools
ARG DISTROBUILDER_VERSION
ARG SKOPEO_VERSION
ARG UMOCI_VERSION
# Fall back to direct downloads on any proxy error.
ENV GOPROXY="https://proxy.golang.org|direct"
WORKDIR /src
COPY docker/image-builder/build-tools.sh /usr/local/bin/build-tools.sh
RUN sh /usr/local/bin/build-tools.sh

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Runtime tools; containers-common provides the skopeo config.
RUN printf 'Acquire::Retries "5";\n' > /etc/apt/apt.conf.d/80-retries && \
    apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates wget git \
    debootstrap rsync gpg dirmngr squashfs-tools \
    parted dosfstools e2fsprogs kmod \
    initramfs-tools fdisk gdisk udev kpartx \
    xz-utils bzip2 zstd \
    python3 \
    golang-github-containers-common \
    && rm -rf /var/lib/apt/lists/*

COPY --from=tools /out/ /usr/local/bin/
# distrobuilder needs privileges even for --version.
RUN test -x /usr/local/bin/distrobuilder && skopeo --version && umoci --version

WORKDIR /build

COPY docker/image-builder/entrypoint.sh /entrypoint.sh
COPY docker/image-builder/entrypoint-multi.sh /entrypoint-multi.sh
RUN chmod +x /entrypoint.sh /entrypoint-multi.sh

ENTRYPOINT ["/entrypoint.sh"]
