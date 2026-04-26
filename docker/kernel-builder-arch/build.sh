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
PKGNAME="linux-custom"
VERSION=${KVER%%-*}

echo "==> Packaging kernel $KVER as pacman package"

STAGING=$(mktemp -d)

# Copy staged boot artifacts
mkdir -p "$STAGING/boot"
cp /out/staging/boot/bzImage "$STAGING/boot/vmlinuz-$KVER"
cp /out/staging/System.map   "$STAGING/boot/System.map-$KVER"
cp /out/staging/.config      "$STAGING/boot/config-$KVER"

# Copy pre-installed modules (Arch uses /lib -> /usr/lib)
mkdir -p "$STAGING/usr/lib/modules"
cp -a "/out/staging/lib/modules/$KVER" "$STAGING/usr/lib/modules/"

# Create .PKGINFO
BUILDDATE=$(date -u +%s)
INSTALLED_SIZE=$(du -sb "$STAGING" | awk '{print $1}')
cat > "$STAGING/.PKGINFO" << EOF
pkgname = $PKGNAME
pkgbase = $PKGNAME
pkgver = ${VERSION}-1
pkgdesc = Custom Linux kernel $KVER for PS5
url = https://kernel.org
builddate = $BUILDDATE
packager = bootstrap_docker
size = $INSTALLED_SIZE
arch = x86_64
license = GPL-2.0-only
provides = linux=$VERSION
provides = linux-custom=$VERSION
EOF

# Create .MTREE (required by newer pacman)
cd "$STAGING"
LANG=C bsdtar -czf .MTREE --format=mtree \
    --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
    .PKGINFO *

# Build the package
LANG=C bsdtar -cf - .PKGINFO .MTREE * | zstd -c -T0 > "/out/${PKGNAME}-${VERSION}-1-x86_64.pkg.tar.zst"

echo "==> Done: /out/${PKGNAME}-${VERSION}-1-x86_64.pkg.tar.zst"
