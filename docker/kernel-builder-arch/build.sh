#!/bin/bash
# Packages pre-built kernel artifacts as a pacman .pkg.tar.zst.
# Runs inside Docker as root; packages manually (makepkg refuses root).
# Expects build artifacts staged in /out/staging by the ubuntu build step.
set -e

if [ ! -f /out/staging/boot/bzImage ]; then
    echo "Error: no staged artifacts in /out/staging — run the kernel build step first"
    exit 1
fi

# Determine version from staged modules directory
KVER=$(ls /out/staging/lib/modules/)
PKGNAME="linux-ps5"
VERSION=${KVER%%-*}

echo "==> Packaging kernel $KVER as pacman package"

STAGING=$(mktemp -d)

# Copy staged boot artifacts
mkdir -p "$STAGING/boot"
cp /out/staging/boot/bzImage "$STAGING/boot/vmlinuz-$KVER"
cp /out/staging/System.map   "$STAGING/boot/System.map-$KVER"
cp /out/staging/.config      "$STAGING/boot/config-$KVER"

# Copy pre-installed modules (Arch uses /usr/lib/modules)
mkdir -p "$STAGING/usr/lib/modules"
cp -a "/out/staging/lib/modules/$KVER" "$STAGING/usr/lib/modules/"

# Kernel headers (for out-of-tree module builds)
if [ -d /out/staging/headers ]; then
    # UAPI headers (/usr/include/linux/, /usr/include/asm/, etc.)
    cp -a /out/staging/headers/usr "$STAGING/usr"
    # Build headers (/usr/lib/modules/$KVER/build/)
    mkdir -p "$STAGING/usr/lib/modules/$KVER"
    cp -a /out/staging/headers/lib/modules/$KVER/build "$STAGING/usr/lib/modules/$KVER/build"
fi

# Create .INSTALL from template, baking in KVER
sed "s/__KVER__/$KVER/g" /install.sh > "$STAGING/.INSTALL"

# Create .PKGINFO
BUILDDATE=$(date -u +%s)
INSTALLED_SIZE=$(du -sb "$STAGING" | awk '{print $1}')
cat > "$STAGING/.PKGINFO" << EOF
pkgname = $PKGNAME
pkgbase = $PKGNAME
pkgver = ${VERSION}-1
pkgdesc = PS5 Linux kernel $KVER (image + modules + headers)
url = https://kernel.org
builddate = $BUILDDATE
packager = ps5-linux
size = $INSTALLED_SIZE
arch = x86_64
license = GPL-2.0-only
provides = linux=$VERSION
provides = linux-headers=$VERSION
provides = linux-api-headers=$VERSION
conflict = linux
conflict = linux-headers
conflict = linux-api-headers
conflict = linux-custom
replaces = linux
replaces = linux-headers
replaces = linux-api-headers
replaces = linux-custom
EOF

# Create .MTREE (required by newer pacman)
cd "$STAGING"
LANG=C bsdtar -czf .MTREE --format=mtree \
    --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
    .PKGINFO .INSTALL *

# Build the package
LANG=C bsdtar -cf - .PKGINFO .INSTALL .MTREE * | zstd -c -T0 > "/out/${PKGNAME}-${VERSION}-1-x86_64.pkg.tar.zst"

echo "==> Done: /out/${PKGNAME}-${VERSION}-1-x86_64.pkg.tar.zst"
