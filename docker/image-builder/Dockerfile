# syntax=docker/dockerfile:1

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
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build <<'EOF'
set -eu
retry() { for i in 1 2 3; do "$@" && return 0; sleep 15; done; return 1; }
fetch() { rm -rf "$2"; git clone --depth 1 --branch "$1" "$3" "$2"; }

retry fetch "$DISTROBUILDER_VERSION" distrobuilder https://github.com/lxc/distrobuilder
retry fetch "$SKOPEO_VERSION" skopeo https://github.com/containers/skopeo
retry fetch "$UMOCI_VERSION" umoci https://github.com/opencontainers/umoci

# Tags from distrobuilder's Makefile.
cd /src/distrobuilder && retry go build \
    -tags "containers_image_storage_stub containers_image_docker_daemon_stub containers_image_openpgp" \
    -o /out/distrobuilder ./distrobuilder
export CGO_ENABLED=0
cd /src/skopeo && retry go build \
    -tags "containers_image_openpgp exclude_graphdriver_btrfs" -o /out/skopeo ./cmd/skopeo
cd /src/umoci && retry go build -ldflags "-X github.com/opencontainers/umoci.version=${UMOCI_VERSION#v}" \
    -o /out/umoci ./cmd/umoci
EOF

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

COPY --chmod=0755 docker/image-builder/entrypoint.sh /entrypoint.sh
COPY --chmod=0755 docker/image-builder/entrypoint-multi.sh /entrypoint-multi.sh

ENTRYPOINT ["/entrypoint.sh"]
