#!/bin/bash
# Multi-distro image builder: builds multiple distros into a single
# GPT image (shared FAT32 boot + one ext4 rootfs partition per distro).
set -ex

IMG_SIZE="${IMG_SIZE:-32000}"
SKIP_CHROOT="${SKIP_CHROOT:-false}"
DISTROS="${DISTROS:-ubuntu2604 arch alpine cachyos}"
STAGING="/tmp/build-staging"
EFI_LABEL="boot"
IMG="/output/ps5-multi.img"
NUM_DISTROS=$(echo $DISTROS | wc -w)

# ======================================================================
# Step 1: Build each distro's rootfs via distrobuilder
# ======================================================================
for DISTRO in $DISTROS; do
    CHROOT="/build/chroot-${DISTRO}"
    ROOT_LABEL="$DISTRO"

    if [ "$SKIP_CHROOT" = "true" ] && [ -d "$CHROOT/bin" ]; then
        echo "=== Skipping $DISTRO chroot build, reusing existing rootfs ==="
    else
        echo "=== Building $DISTRO rootfs ==="

        # --- Stage files for distrobuilder's copy generators ---
        rm -rf "$STAGING"
        mkdir -p "$STAGING/debs" "$STAGING/pkgs"

        # Use the multi-boot hook instead of the single-distro one
        cp /repo/distros/shared/zz-update-boot-multi "$STAGING/zz-update-boot"

        # Generate per-distro fstab with partition labels
        printf 'LABEL=%-14s /          ext4  rw,relatime  0 1\nLABEL=%-14s /boot/efi  vfat  rw,relatime  0 2\n' \
            "$ROOT_LABEL" "$EFI_LABEL" > "$STAGING/fstab"

        cp /repo/distros/${DISTRO}/nm-dns.conf   "$STAGING/" 2>/dev/null || true

        case "$DISTRO" in
            ubuntu*)
                cp /repo/distros/${DISTRO}/grow-rootfs   "$STAGING/"
                cp /repo/distros/${DISTRO}/grow-rootfs.service "$STAGING/"
                cp /kernel-debs/*.deb                          "$STAGING/debs/"
                ;;
            alpine)
                cp /repo/distros/${DISTRO}/grow-rootfs         "$STAGING/"
                cp /repo/distros/alpine/grow-rootfs.openrc     "$STAGING/"
                ;;
            arch)
                cp /repo/distros/${DISTRO}/grow-rootfs         "$STAGING/"
                cp /repo/distros/arch/grow-rootfs.service      "$STAGING/"
                cp /repo/distros/arch/first-boot-setup         "$STAGING/"
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
                cp /kernel-debs/*.pkg.tar.zst                             "$STAGING/pkgs/"
                ;;
        esac

        # --- Build rootfs ---
        rm -rf "$CHROOT"/* "$CHROOT"/.[!.]* 2>/dev/null || true
        mkdir -p "$CHROOT"

        YAML="/repo/distros/${DISTRO}/image.yaml"
        distrobuilder build-dir "$YAML" "$CHROOT" --with-post-files --cache-dir /build/cache --cleanup=false

        # --- Post-distrobuilder fixups ---
        case "$DISTRO" in
            ubuntu*)
                rm -f "$CHROOT/etc/resolv.conf"
                ln -sf /run/systemd/resolve/stub-resolv.conf "$CHROOT/etc/resolv.conf"
                ;;
        esac

        # Write distro marker
        echo "$DISTRO" > "$CHROOT/etc/ps5-distro"
    fi

    # --- Alpine kernel gap: no kernel installed via image.yaml ---
    # This runs even with --skip-chroot because Alpine's rootfs never includes a kernel;
    # we must always extract it from the .deb artifacts and generate an initrd.
    if [ "$DISTRO" = "alpine" ]; then
        echo "=== Alpine: installing kernel from .deb artifacts ==="

        # Extract modules + vmlinuz from the linux-image .deb
        ALPINE_STAGING="/tmp/alpine-kernel-staging"
        rm -rf "$ALPINE_STAGING"
        mkdir -p "$ALPINE_STAGING"
        for deb in /kernel-debs/linux-image-*.deb; do
            [ -f "$deb" ] || continue
            dpkg-deb -x "$deb" "$ALPINE_STAGING"
        done

        # Identify kernel version from the extracted .deb before copying
        KVER=$(ls -1 "$ALPINE_STAGING/lib/modules" 2>/dev/null | head -1)

        if [ -n "$KVER" ]; then
            # Resolve the real modules path inside the chroot.
            # Alpine may use usr-merge (/lib -> usr/lib), so we must follow
            # symlinks to find the actual directory on disk.
            if [ -L "$CHROOT/lib" ]; then
                MODDIR="$CHROOT/usr/lib/modules"
            else
                MODDIR="$CHROOT/lib/modules"
            fi
            mkdir -p "$MODDIR"
            # Remove any stale modules from a previous build
            rm -rf "$MODDIR/$KVER"
            cp -a "$ALPINE_STAGING/lib/modules/$KVER" "$MODDIR/"
            mkdir -p "$CHROOT/boot"
            cp "$ALPINE_STAGING/boot/vmlinuz-$KVER" "$CHROOT/boot/vmlinuz-$KVER"
            echo ">> Alpine: modules copied to $MODDIR/$KVER"
            ls -la "$MODDIR/"
        fi
        rm -rf "$ALPINE_STAGING"

        if [ -n "$KVER" ]; then
            echo "=== Alpine: generating initrd ==="
            chroot "$CHROOT" depmod -a "$KVER" 2>/dev/null || true

            # Bind-mount essentials and run mkinitfs inside the alpine chroot
            mount --bind /dev  "$CHROOT/dev"
            mount --bind /proc "$CHROOT/proc"
            mount --bind /sys  "$CHROOT/sys"
            chroot "$CHROOT" mkinitfs -k "$KVER" -o "/boot/initrd.img-$KVER" "$KVER" || true
            umount "$CHROOT/sys" "$CHROOT/proc" "$CHROOT/dev"

            # Populate /boot/efi/ for boot partition assembly
            mkdir -p "$CHROOT/boot/efi"
            cp "$CHROOT/boot/vmlinuz-$KVER" "$CHROOT/boot/efi/bzImage"
            # mkinitfs may output as initramfs-<flavor> — find whatever was generated
            if [ -f "$CHROOT/boot/initrd.img-$KVER" ]; then
                cp "$CHROOT/boot/initrd.img-$KVER" "$CHROOT/boot/efi/initrd.img"
            else
                # mkinitfs default output: /boot/initramfs-vanilla or similar
                INITRD=$(ls -1t "$CHROOT"/boot/initramfs-* "$CHROOT"/boot/initrd* 2>/dev/null | head -1)
                if [ -n "$INITRD" ]; then
                    cp "$INITRD" "$CHROOT/boot/efi/initrd.img"
                else
                    echo "WARNING: No initrd found for alpine after mkinitfs"
                fi
            fi
            echo ">> Alpine: kernel $KVER staged to boot/efi/"
        else
            echo "WARNING: No kernel modules found in .deb for alpine, skipping initrd generation"
        fi
    fi
done

# ======================================================================
# Step 2: Create GPT image with dynamic partition layout
# ======================================================================
echo "=== Creating ${IMG_SIZE}MB GPT image ==="
TMPIMG="/build/ps5-multi.img"
dd if=/dev/zero of="$TMPIMG" bs=1M count=$IMG_SIZE conv=fsync status=progress

BOOT_END=500  # MiB
USABLE=$((IMG_SIZE - BOOT_END))
PER_DISTRO=$((USABLE / NUM_DISTROS))

parted -s "$TMPIMG" mklabel gpt
parted -s "$TMPIMG" mkpart primary fat32 1MiB ${BOOT_END}MiB
parted -s "$TMPIMG" set 1 esp on

PART_START=$BOOT_END
PART_I=1
for DISTRO in $DISTROS; do
    if [ $PART_I -lt $NUM_DISTROS ]; then
        PART_END=$((PART_START + PER_DISTRO))
        parted -s "$TMPIMG" mkpart primary ext4 ${PART_START}MiB ${PART_END}MiB
    else
        parted -s "$TMPIMG" mkpart primary ext4 ${PART_START}MiB 100%
    fi
    PART_START=$((PART_START + PER_DISTRO))
    PART_I=$((PART_I + 1))
done

# ======================================================================
# Step 3: Setup loop device + format partitions
# ======================================================================
LOOP_PATH=$(losetup -f)
if [ ! -e "$LOOP_PATH" ]; then
    LOOP_NUM=${LOOP_PATH#/dev/loop}
    mknod "$LOOP_PATH" b 7 "$LOOP_NUM"
fi

LOOPDEV=$(losetup -f --show "$TMPIMG")
kpartx -av "$LOOPDEV"
sleep 1

LOOP_BASE=$(basename "$LOOPDEV")
PART_BOOT="/dev/mapper/${LOOP_BASE}p1"

echo "=== Formatting partitions ==="
mkfs.vfat -n "$EFI_LABEL" -F32 "$PART_BOOT"

PART_NUM=2
for DISTRO in $DISTROS; do
    PART="/dev/mapper/${LOOP_BASE}p${PART_NUM}"
    mkfs.ext4 -L "$DISTRO" -m 1 "$PART"
    PART_NUM=$((PART_NUM + 1))
done

# ======================================================================
# Step 4: Copy each rootfs to its partition
# ======================================================================
mkdir -p /tmp/mnt_boot /tmp/mnt_root

PART_NUM=2
for DISTRO in $DISTROS; do
    echo "=== Copying $DISTRO rootfs ==="
    PART="/dev/mapper/${LOOP_BASE}p${PART_NUM}"
    mount "$PART" /tmp/mnt_root
    cp -a "/build/chroot-${DISTRO}"/* /tmp/mnt_root/
    sync
    umount /tmp/mnt_root
    PART_NUM=$((PART_NUM + 1))
done

# ======================================================================
# Step 5: Assemble boot partition
# ======================================================================
echo "=== Assembling boot partition ==="
mount "$PART_BOOT" /tmp/mnt_boot

# Collect boot files from each distro's chroot.
# Prefer /boot/efi/ (populated by fresh builds), fallback to /boot/ (skip-chroot reruns).
for DISTRO in $DISTROS; do
    CHROOT="/build/chroot-${DISTRO}"
    EFIDIR="$CHROOT/boot/efi"
    BOOTDIR="$CHROOT/boot"
    # Find kernel version: look for versioned directories (not 'kernel'), following symlinks
    MODBASE="$CHROOT/lib/modules"
    [ -L "$CHROOT/lib" ] && MODBASE="$CHROOT/usr/lib/modules"
    KVER=$(find "$MODBASE" -maxdepth 1 -mindepth 1 -type d -not -name 'kernel' -printf '%f\n' 2>/dev/null | sort -V | tail -1)

    # Copy bzImage (shared kernel — same for all, just copy once)
    if [ ! -f /tmp/mnt_boot/bzImage ]; then
        if [ -f "$EFIDIR/bzImage" ]; then
            cp "$EFIDIR/bzImage" /tmp/mnt_boot/
        elif [ -n "$KVER" ] && [ -f "$BOOTDIR/vmlinuz-$KVER" ]; then
            cp "$BOOTDIR/vmlinuz-$KVER" /tmp/mnt_boot/bzImage
        fi
    fi

    # Copy distro-specific initrd
    if [ -f "$EFIDIR/initrd.img" ]; then
        cp "$EFIDIR/initrd.img" "/tmp/mnt_boot/initrd-${DISTRO}.img"
    elif [ -n "$KVER" ] && [ -f "$BOOTDIR/initrd.img-$KVER" ]; then
        cp "$BOOTDIR/initrd.img-$KVER" "/tmp/mnt_boot/initrd-${DISTRO}.img"
    elif [ -f "$BOOTDIR/initramfs-vanilla" ]; then
        # Alpine mkinitfs names its output initramfs-vanilla
        cp "$BOOTDIR/initramfs-vanilla" "/tmp/mnt_boot/initrd-${DISTRO}.img"
    fi

    # Clean up /boot/efi contents from the rootfs (they're on the boot partition now)
    rm -rf "$CHROOT/boot/efi"/*
done

# Ubuntu 26.04 is default boot — copy its initrd as the generic initrd.img
if [ -f /tmp/mnt_boot/initrd-ubuntu2604.img ]; then
    cp /tmp/mnt_boot/initrd-ubuntu2604.img /tmp/mnt_boot/initrd.img
fi

# Generate per-distro cmdline files
for DISTRO in $DISTROS; do
    sed "s|__DISTRO__|${DISTRO}|" /repo/boot/cmdline.txt > "/tmp/mnt_boot/cmdline-${DISTRO}.txt"
done

# Default cmdline points to ubuntu2604
sed "s|__DISTRO__|ubuntu2604|" /repo/boot/cmdline.txt > /tmp/mnt_boot/cmdline.txt

# Copy kexec scripts
for DISTRO in $DISTROS; do
    cp "/repo/boot/kexec-${DISTRO}.sh" /tmp/mnt_boot/
    chmod +x "/tmp/mnt_boot/kexec-${DISTRO}.sh"
done

# Copy vram.txt
cp /repo/boot/vram.txt /tmp/mnt_boot/
sync

# ======================================================================
# Step 6: Cleanup
# ======================================================================
umount /tmp/mnt_boot
rmdir /tmp/mnt_boot /tmp/mnt_root
kpartx -dv "$LOOPDEV"
losetup -d "$LOOPDEV"

mv "$TMPIMG" "$IMG"
sync

echo "========================================"
echo "Done! $IMG (${IMG_SIZE}MB) — $(echo $DISTROS | tr ' ' ' + ')"
echo "Flash: sudo dd if=$IMG of=/dev/sdX bs=4M status=progress"
echo "========================================"
