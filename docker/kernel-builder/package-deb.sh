#!/bin/bash
# Builds a combined linux-ps5 .deb from the kernel source at /src.
# Runs inside the kernel-builder container; output goes to /out.
set -e

make -j$(nproc) DPKG_FLAGS=-d bindeb-pkg

VER=$(dpkg-deb -f "$(ls /linux-image-[0-9]*.deb | grep -v dbg | head -1)" Version)
ARCH=$(dpkg-deb -f "$(ls /linux-image-[0-9]*.deb | grep -v dbg | head -1)" Architecture)
KVER=$(ls /src/debian/linux-image-[0-9]*/lib/modules/ 2>/dev/null | head -1)

TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/DEBIAN"
for deb in $(ls /linux-image-[0-9]*.deb /linux-headers-*.deb /linux-libc-dev_*.deb 2>/dev/null | grep -v -- '-dbg_'); do
    dpkg-deb -x "$deb" "$TMPDIR"
done

cat > "$TMPDIR/DEBIAN/control" << CTRL
Package: linux-ps5
Version: $VER
Architecture: $ARCH
Maintainer: PS5 Linux
Provides: linux-image, linux-image-$KVER, linux-headers-$KVER, linux-libc-dev
Conflicts: linux-image-$KVER, linux-headers-$KVER, linux-libc-dev
Replaces: linux-image-$KVER, linux-headers-$KVER, linux-libc-dev
Description: PS5 Linux kernel $KVER (image + headers + libc-dev)
CTRL

dpkg-deb --build --root-owner-group "$TMPDIR" "/out/linux-ps5_${VER}_${ARCH}.deb"
