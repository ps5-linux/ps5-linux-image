#!/bin/sh
# Build distrobuilder, skopeo and umoci into /out.
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
