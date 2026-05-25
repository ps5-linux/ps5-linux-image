#!/bin/bash
set -ex

DISTRO="${DISTRO:-ubuntu2604}"
IMG_SIZE="${IMG_SIZE:-12000}"
SKIP_CHROOT="${SKIP_CHROOT:-false}"
STAGING="/tmp/build-staging"
ROOT_LABEL="${DISTRO}"
EFI_LABEL="boot"
CHROOT="/build/chroot"
IMG="/output/ps5-${DISTRO}.img"

if [ "$DISTRO" = "kali" ]; then
    ROOT_LABEL="kali-root"
fi

if [ "$SKIP_CHROOT" = "true" ] && [ -d "$CHROOT/bin" ]; then
    echo "=== Reusing cached $DISTRO rootfs ==="
else
    echo "=== Building $DISTRO rootfs ==="
    # --- Stage files for distrobuilder's copy generators ---
    rm -rf "$STAGING"
    mkdir -p "$STAGING/debs"
    cp /repo/distros/shared/zz-update-boot      "$STAGING/"
    # Generate per-distro fstab with partition labels
    cat <<EOF > "$STAGING/fstab"
# /etc/fstab: static file system information.
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
LABEL=$ROOT_LABEL / ext4 defaults 0 1
LABEL=$EFI_LABEL /boot/efi vfat defaults 0 1
EOF
    cp /repo/distros/${DISTRO}/nm-dns.conf       "$STAGING/" 2>/dev/null || true

    case "$DISTRO" in
        ubuntu*)
            cp /repo/distros/${DISTRO}/grow-rootfs       "$STAGING/"
            cp /repo/distros/${DISTRO}/grow-rootfs.service "$STAGING/"
            cp /kernel-debs/*.deb                          "$STAGING/debs/"
            ;;
        kali)
            cp /repo/distros/${DISTRO}/grow-rootfs          "$STAGING/"
            cp /repo/distros/${DISTRO}/grow-rootfs.service  "$STAGING/"
            cp /repo/distros/${DISTRO}/kali-archive-keyring.asc "$STAGING/"
            cp /kernel-debs/*.deb                           "$STAGING/debs/"
            ;;
        arch)
            cp /repo/distros/${DISTRO}/grow-rootfs         "$STAGING/"
            cp /repo/distros/arch/grow-rootfs.service      "$STAGING/"
            cp /repo/distros/arch/first-boot-setup         "$STAGING/"
            mkdir -p "$STAGING/pkgs"
            cp /kernel-debs/*.pkg.tar.zst                  "$STAGING/pkgs/"
            ;;
        cachyos)
            mkdir -p "$STAGING/files"
            cp /repo/distros/cachyos/files/grow-rootfs                "$STAGING/files/"
            cp /repo/distros/cachyos/files/grow-rootfs.service        "$STAGING/files/"
            cp /repo/distros/cachyos/files/first-boot-setup           "$STAGING/files/"
            cp /repo/distros/cachyos/files/first-boot.service         "$STAGING/files/"
            cp /repo/distros/cachyos/files/gamescope-session-ps5      "$STAGING/files/"
            cp /repo/distros/cachyos/files/steamos-session-select     "$STAGING/files/"
            cp /repo/distros/cachyos/files/return-to-gaming-mode.desktop "$STAGING/files/"
            cp /repo/distros/cachyos/files/ps5-display.lua            "$STAGING/files/"
            cp /repo/distros/cachyos/files/plasma-workspace-env-ps5.sh "$STAGING/files/"
            cp /repo/distros/cachyos/files/ps5-tty-session.sh         "$STAGING/files/"
            mkdir -p "$STAGING/pkgs"
            cp /kernel-debs/*.pkg.tar.zst                             "$STAGING/pkgs/"
            ;;
    esac

    find "$STAGING" -type f \
        ! -path "$STAGING/debs/*" \
        ! -path "$STAGING/pkgs/*" \
        -exec sed -i 's/\r$//' {} +

    # --- Build rootfs ---
    rm -rf "$CHROOT"/* "$CHROOT"/.[!.]* 2>/dev/null || true

    YAML="/repo/distros/${DISTRO}/image.yaml"
    distrobuilder build-dir "$YAML" "$CHROOT" --with-post-files --cache-dir /build/cache --cleanup=false
fi

# --- Post-distrobuilder fixups ---
case "$DISTRO" in
    ubuntu*)
        rm -f "$CHROOT/etc/resolv.conf"
        ln -sf /run/systemd/resolve/stub-resolv.conf "$CHROOT/etc/resolv.conf"
        ;;
esac

# --- Create GPT disk image ---
echo "=== Creating ${IMG_SIZE}MB disk image ==="
TMPIMG="/output/.ps5-${DISTRO}.img.tmp"
rm -f "$TMPIMG"
truncate -s "${IMG_SIZE}M" "$TMPIMG"
sync

parted -s "$TMPIMG" mklabel gpt
parted -s "$TMPIMG" mkpart primary ext4  500MiB 100%
parted -s "$TMPIMG" mkpart primary fat32 1MiB   500MiB
parted -s "$TMPIMG" set 2 esp on

# Ensure the free loop device node exists (udev doesn't run inside containers,
# so when the kernel allocates a new loop number it may lack a /dev node)
LOOP_PATH=$(losetup -f)
if [ ! -e "$LOOP_PATH" ]; then
    LOOP_NUM=${LOOP_PATH#/dev/loop}
    mknod "$LOOP_PATH" b 7 "$LOOP_NUM"
fi

LOOPDEV=$(losetup -f --show "$TMPIMG")
# Use kpartx to create partition device mappings (more reliable in containers)
kpartx -av "$LOOPDEV"
sleep 1

# kpartx creates /dev/mapper/loopXp1, /dev/mapper/loopXp2
LOOP_BASE=$(basename "$LOOPDEV")
PART1="/dev/mapper/${LOOP_BASE}p1"
PART2="/dev/mapper/${LOOP_BASE}p2"

echo "=== Formatting partitions ==="
mkfs.ext4 -L "$ROOT_LABEL" -m 1  "$PART1"
mkfs.vfat -n "$EFI_LABEL"  -F32  "$PART2"

mkdir -p /tmp/usb_root /tmp/usb_efi
mount "$PART1" /tmp/usb_root
mount "$PART2" /tmp/usb_efi

echo "=== Copying rootfs to image ==="
cp -a "$CHROOT"/* /tmp/usb_root/
sync

echo "=== Assembling boot partition ==="
mv /tmp/usb_root/boot/efi/* /tmp/usb_efi/ 2>/dev/null || true
CMDLINE_TEMPLATE="/repo/distros/${DISTRO}/cmdline.txt"
[ -f "$CMDLINE_TEMPLATE" ] || CMDLINE_TEMPLATE="/repo/boot/cmdline.txt"
sed "s|__DISTRO__|$ROOT_LABEL|" "$CMDLINE_TEMPLATE" > /tmp/usb_efi/cmdline.txt
cp /repo/boot/vram.txt     /tmp/usb_efi/
cp /repo/boot/kexec.sh     /tmp/usb_efi/
sync

umount /tmp/usb_root /tmp/usb_efi
rmdir  /tmp/usb_root /tmp/usb_efi
kpartx -dv "$LOOPDEV"
losetup -d "$LOOPDEV"

# Move finished image to output volume
mv "$TMPIMG" "$IMG"
sync

echo "========================================"
echo "Done! $IMG (${IMG_SIZE}MB)"
echo "Flash: sudo dd if=$IMG of=/dev/sdX bs=4M status=progress"
echo "========================================"
