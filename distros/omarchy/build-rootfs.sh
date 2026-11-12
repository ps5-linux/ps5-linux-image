#!/bin/bash
# distros/omarchy/build-rootfs.sh — Arch rootfs + the real Omarchy packages.
# Called from docker/image-builder/entrypoint.sh for DISTRO=omarchy.
#
# Omarchy's installer is an ISO wizard, but the Omarchy packages are normal Arch
# packages in Omarchy's own repo, and Omarchy's docs cover image builds: a
# prebuilt image carries the packages and defers hardware setup to first boot
# (docs/file-layout.md). The distrobuilder recipe (image.yaml) installs the Arch
# side, pulls the Omarchy packages from here and then runs
# distros/omarchy/post-install.sh — the same system setup Omarchy's installer
# runs in the target chroot.
#
# Expects in env: DISTRO=omarchy, CHROOT, KVER, ROOT_LABEL, EFI_LABEL
# Expects on disk: /kernel-debs/linux-ps5-*.pkg.tar.zst,
#                  /repo/distros/omarchy/{grow-rootfs,grow-rootfs.service},
#                  /repo/distros/shared/zz-update-boot
set -eux
: "${CHROOT:?ERROR: \$CHROOT unset/empty}"
[ -d "$CHROOT" ] || { echo "ERROR: \$CHROOT=$CHROOT not a directory"; exit 2; }
case "$CHROOT" in /) echo "ERROR: refuse to operate on /"; exit 2 ;; esac

STAGING=/tmp/build-staging
OMARCHY_CHANNEL="${OMARCHY_CHANNEL:-stable}"
OMARCHY_REPO_URL="${OMARCHY_REPO_URL:-https://pkgs.omarchy.org/$OMARCHY_CHANNEL/x86_64}"
OMARCHY_MIRROR_URL="${OMARCHY_MIRROR_URL:-https://$OMARCHY_CHANNEL-mirror.omarchy.org}"

# --- Stage files distrobuilder's copy generators need ------------------------
rm -rf "$STAGING"
mkdir -p "$STAGING/pkgs"
cp /repo/distros/omarchy/grow-rootfs          "$STAGING/"
cp /repo/distros/omarchy/grow-rootfs.service  "$STAGING/"
cp /repo/distros/shared/zz-update-boot        "$STAGING/"
cp /kernel-debs/*.pkg.tar.zst                 "$STAGING/pkgs/"
cat > "$STAGING/fstab" <<EOF
# /etc/fstab: static file system information.
#
# <file system> <mount point>   <type> <options>       <dump> <pass>
LABEL=$ROOT_LABEL / ext4 defaults 0 1
LABEL=$EFI_LABEL /boot/efi vfat defaults 0 1
EOF
find "$STAGING" -type f ! -path "$STAGING/pkgs/*" -exec sed -i 's/\r$//' {} +

if [ "${SKIP_CHROOT:-false}" = "true" ] && [ -d "$CHROOT/usr/share/omarchy" ]; then
    echo "=== Reusing cached $DISTRO rootfs ==="
    exit 0
fi

# --- Omarchy packages, fetched once and reused across rebuilds ---------------
echo "=== Fetching Omarchy $OMARCHY_CHANNEL packages ==="
OMARCHY_CHANNEL="$OMARCHY_CHANNEL" \
OMARCHY_REPO_URL="$OMARCHY_REPO_URL" \
OMARCHY_MIRROR_URL="$OMARCHY_MIRROR_URL" \
    bash /repo/distros/omarchy/stage-pkgs.sh /build/cache/omarchy >&2

rm -rf "$CHROOT"/* "$CHROOT"/.[!.]* 2>/dev/null || true
mkdir -p "$CHROOT"
cp -a /build/cache/omarchy/omarchy-pkgs "$CHROOT/omarchy-pkgs"
cp -a /build/cache/omarchy/omarchy-db   "$CHROOT/omarchy-db"
distrobuilder build-dir /repo/distros/omarchy/image.yaml "$CHROOT" \
    --with-post-files --cache-dir /build/cache --cleanup=false >&2
rm -rf "$CHROOT/omarchy-pkgs" "$CHROOT/omarchy-db"
