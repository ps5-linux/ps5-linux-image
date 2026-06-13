#!/bin/bash
# Packages pre-built kernel artifacts as an rpm.
# Runs inside Docker as root.
# Expects build artifacts staged in /out/staging by the kernel build step.
set -e

if [ ! -f /out/staging/boot/bzImage ]; then
    echo "Error: no staged artifacts in /out/staging — run the kernel build step first"
    exit 1
fi

# Determine version from staged modules directory
KVER=$(ls /out/staging/lib/modules/)
PKGNAME="linux-ps5"
VERSION=${KVER%%-*}

echo "==> Packaging kernel $KVER as rpm"

RPMROOT=$(mktemp -d)
STAGE="$RPMROOT/stage"

# Copy staged boot artifacts
mkdir -p "$STAGE/boot"
cp /out/staging/boot/bzImage "$STAGE/boot/vmlinuz-$KVER"
cp /out/staging/System.map   "$STAGE/boot/System.map-$KVER"
cp /out/staging/.config      "$STAGE/boot/config-$KVER"

# Copy pre-installed modules (Fedora uses /usr/lib/modules)
mkdir -p "$STAGE/usr/lib/modules"
cp -a "/out/staging/lib/modules/$KVER" "$STAGE/usr/lib/modules/"

# Build headers for out-of-tree module builds. UAPI headers (/usr/include)
# are intentionally excluded — they would conflict with Fedora's
# kernel-headers package.
if [ -d "/out/staging/headers/lib/modules/$KVER/build" ]; then
    cp -a "/out/staging/headers/lib/modules/$KVER/build" \
          "$STAGE/usr/lib/modules/$KVER/build"
fi

rpmbuild -bb \
    --define "_topdir $RPMROOT/rpmbuild" \
    --define "stagedir $STAGE" \
    --define "kver $KVER" \
    --define "ver $VERSION" \
    /linux-ps5.spec

cp "$RPMROOT/rpmbuild/RPMS/x86_64/${PKGNAME}-${VERSION}-1.x86_64.rpm" /out/

echo "==> Done: /out/${PKGNAME}-${VERSION}-1.x86_64.rpm"
