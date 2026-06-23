#!/bin/bash
# distros/batocera/build-rootfs.sh — download upstream batocera image, extract
# its squashfs to $CHROOT, swap in our PS5 kernel + modules.  Called from
# docker/image-builder/entrypoint.sh for DISTRO=batocera*.
#
# Batocera is Buildroot-based, shipping as a single .img.gz with FAT32 boot +
# ext4 SHARE partitions; the OS itself lives in a squashfs file at
# /boot/batocera on the FAT32.  We unsquash, swap kernel + modules in, and
# the rest of the standard image-builder flow packs it onto ext4.
#
# Expects in env: DISTRO, CHROOT, KVER, ROOT_LABEL, EFI_LABEL
# Expects on disk: /kernel-debs/*.deb (linux-ps5 .deb to extract bzImage from)

set -ex

: "${CHROOT:?ERROR: \$CHROOT unset/empty}"
[ -d "$CHROOT" ] || { echo "ERROR: \$CHROOT=$CHROOT not a directory"; exit 2; }
case "$CHROOT" in /) echo "ERROR: refuse to operate on /"; exit 2 ;; esac

# Batocera is a Buildroot-based emulation distro. It ships as a
# single .img.gz with FAT32 boot + ext4 SHARE partitions; the OS
# itself lives in a squashfs file (`/boot/batocera`) on the FAT32.
# We unsquash, swap our PS5 kernel + modules in, and let the rest
# of the standard image-builder flow pack everything onto ext4.
# `last/` always points at the current build, but the .img.gz filename
# inside it bakes in the version + date (e.g. batocera-x86_64-43.1-20260529.img.gz),
# and the mirror rotates older builds out. Scrape the index to discover
# whatever's there today rather than hardcoding (the previous hardcoded
# 43-20260430 went 404 within ~4 weeks).
BATOCERA_INDEX_URL="${BATOCERA_INDEX_URL:-https://mirrors.o2switch.fr/batocera/x86_64/stable/last/}"
if [ -z "${BATOCERA_URL:-}" ]; then
    IMG_NAME=$(wget -qO- "$BATOCERA_INDEX_URL" \
        | grep -oE 'batocera-x86_64-[0-9.]+-[0-9]+\.img\.gz' \
        | head -1)
    if [ -z "$IMG_NAME" ]; then
        echo "ERROR: couldn't find a batocera-x86_64-*.img.gz link at $BATOCERA_INDEX_URL"
        exit 1
    fi
    BATOCERA_URL="${BATOCERA_INDEX_URL}${IMG_NAME}"
else
    IMG_NAME="$(basename "$BATOCERA_URL")"
fi
# Pull VER + BUILD out of the discovered (or overridden) filename so the
# cache key + log lines stay informative.
BATOCERA_VER=$(echo "$IMG_NAME"  | sed -E 's/^batocera-x86_64-([0-9.]+)-[0-9]+\.img\.gz$/\1/')
BATOCERA_BUILD=$(echo "$IMG_NAME" | sed -E 's/^batocera-x86_64-[0-9.]+-([0-9]+)\.img\.gz$/\1/')

echo "=== Batocera: locate / download $BATOCERA_VER ($BATOCERA_BUILD) ==="
# /build/cache is per-run temp. The workflow symlinks /build/cache/
# persistent -> /data/cache/ps5/downloads, so the .img.gz can be
# pre-staged or survive between runs. The mirror rate-limits per-IP
# to ~250KB/s sustained (4MB/s burst), so re-downloading every run
# is unacceptably slow.
# The workflow hard-links /data/cache/ps5/downloads/* into
# image/work/cache before the build container starts, so the
# image appears as /build/cache/batocera-*.img.gz inside.
CACHED="/build/cache/batocera-${BATOCERA_VER}-${BATOCERA_BUILD}.img.gz"
if [ ! -s "$CACHED" ]; then
    echo ">> No cached image, downloading (this will be slow due to mirror rate-limiting)"
    wget --tries=3 -O "$CACHED.part" "$BATOCERA_URL"
    mv "$CACHED.part" "$CACHED"
fi
echo ">> Using $CACHED ($(du -h "$CACHED" | cut -f1))"

echo "=== Batocera: decompress + loop ==="
BAT_IMG=/build/batocera-src.img
gunzip -c "$CACHED" > "$BAT_IMG"
BATLOOP=$(losetup -Pf --show "$BAT_IMG")
sleep 1
# kpartx fallback in case partition kernel events didn't fire
[ -e "${BATLOOP}p1" ] || kpartx -av "$BATLOOP"
BAT_MNT=$(mktemp -d)
BAT_PART1=""
for p in "${BATLOOP}p1" "/dev/mapper/$(basename "$BATLOOP")p1"; do
    [ -e "$p" ] && BAT_PART1="$p" && break
done
mount -o ro "$BAT_PART1" "$BAT_MNT"

BAT_SQUASH=""
for c in /boot/batocera /batocera /boot/batocera.update; do
    [ -f "$BAT_MNT$c" ] && BAT_SQUASH="$BAT_MNT$c" && break
done
if [ -z "$BAT_SQUASH" ]; then
    echo "ERROR: squashfs not found in batocera image:"
    find "$BAT_MNT" -maxdepth 3 -type f | head -30
    exit 1
fi
echo "=== Batocera: unsquashfs $BAT_SQUASH -> $CHROOT ==="
unsquashfs -f -d "$CHROOT" "$BAT_SQUASH"

# Batocera ships a SECOND squashfs (boot/rufomaculata) with the
# libretro cores, mame binary, and other emulator assets. At
# runtime it's mounted as a second overlayfs layer on top of the
# main batocera squashfs. We don't do overlay — just unsquash
# rufomaculata on top of $CHROOT so the unified view is realised
# on the ext4 root. Without this, /usr/lib/libretro/ doesn't
# exist and EmulationStation reports "no games start" because
# retroarch fails to load any core.
if [ -f "$BAT_MNT/boot/rufomaculata" ]; then
    echo "=== Batocera: unsquashfs boot/rufomaculata (libretro + mame) -> $CHROOT ==="
    unsquashfs -f -d "$CHROOT" "$BAT_MNT/boot/rufomaculata"
else
    echo "WARN: boot/rufomaculata not found — emulator cores will be missing"
fi

umount "$BAT_MNT"
rmdir "$BAT_MNT"
kpartx -dv "$BATLOOP" 2>/dev/null || true
losetup -d "$BATLOOP"
rm -f "$BAT_IMG"

echo "=== Batocera: install linux-ps5 kernel + modules ==="
KSTAGE=/tmp/bat-kernel-staging
rm -rf "$KSTAGE"; mkdir -p "$KSTAGE"
# The kernel-builder ships a single combined linux-ps5_*.deb
# (Provides: linux-image-X) — there is no linux-image-*.deb on
# disk, so target the actual filename pattern.
shopt -s nullglob
for deb in /kernel-debs/linux-ps5*.deb /kernel-debs/linux-image-*.deb; do
    [ -f "$deb" ] && dpkg-deb -x "$deb" "$KSTAGE"
done
shopt -u nullglob
KVER=$(ls -1 "$KSTAGE/lib/modules" 2>/dev/null | head -1)
if [ -z "$KVER" ]; then
    echo "ERROR: no kernel modules found after dpkg-deb -x of /kernel-debs/*.deb"
    ls -la /kernel-debs/
    exit 1
fi
rm -rf "$CHROOT"/lib/modules/*
cp -a "$KSTAGE/lib/modules/$KVER" "$CHROOT/lib/modules/"
mkdir -p "$CHROOT/boot/efi"
cp "$KSTAGE/boot/vmlinuz-$KVER" "$CHROOT/boot/efi/bzImage"
# depmod -b runs from outside the chroot — Batocera's busybox
# depmod may not be present, and host depmod handles -b cleanly.
depmod -a -b "$CHROOT" "$KVER" || true
# Stage WLAN firmware loader + module autoload (same files the
# debian/fedora paths get from /kernel-debs/staging via .deb).
for src in usr/local/sbin etc/modules-load.d etc/systemd/system; do
    [ -d "$KSTAGE/$src" ] || continue
    mkdir -p "$CHROOT/$src"
    cp -an "$KSTAGE/$src/." "$CHROOT/$src/" || true
done

echo "=== Batocera: PS5 modprobe quirks ==="
mkdir -p "$CHROOT/etc/modprobe.d" "$CHROOT/etc/modules-load.d"
cat > "$CHROOT/etc/modprobe.d/ps5-amdgpu.conf" <<MODPROBE
options amdgpu dpm=0 gpu_recovery=0
MODPROBE
# uinput is needed by Batocera's hotkeygen (for virtual keyboard
# events when launching games). It's not autoloaded by default on
# PS5, so hotkeygen crashes with 'UInputError: /dev/uinput does
# not exist'. Force-load on boot.
cat > "$CHROOT/etc/modules-load.d/uinput.conf" <<MODPROBE
uinput
MODPROBE

echo "=== Batocera: build initrd via host mkinitramfs ==="
# Host (image-builder, ubuntu:24.04) has initramfs-tools. Trick
# it into building for our PS5 kernel by symlinking the chroot's
# modules into /lib/modules/$KVER, then unlinking after.
#
# initramfs-tools default behaviour: autodetect kernel modules
# from /sys on the BUILD HOST — which is a docker container with
# no USB, no amdgpu, no real disks. The resulting initrd would
# ship without xhci_pci / usb_storage / ext4 / amdgpu drivers,
# and the PS5 hangs silently when the kernel tries to find the
# USB root partition. Override with an explicit modules list +
# MODULES=most so initramfs-tools includes everything the PS5
# actually needs at boot.
mkdir -p /lib/modules
ln -sfn "$CHROOT/lib/modules/$KVER" "/lib/modules/$KVER"

cat > /etc/initramfs-tools/modules <<'INITMODS'
# USB host controllers (PS5 boot drive is on USB 3 — xhci is the must-have).
xhci_pci
xhci_hcd
ehci_pci
ehci_hcd
ohci_pci
ohci_hcd
# USB storage class + UAS (faster path).
usb_storage
uas
sd_mod
# Filesystems for root + EFI.
ext4
vfat
nls_iso8859-1
nls_cp437
# Common HID so a USB keyboard works at the initramfs shell if we drop there.
usbhid
hid_generic
INITMODS
# Force MODULES=most (curated full driver set, no autodetect).
sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf

mkinitramfs -k "$KVER" -o "$CHROOT/boot/efi/initrd.img"
rm -f "/lib/modules/$KVER"
rm -rf "$KSTAGE"

echo "=== Batocera: patch configgen to bind HOTKEY combos on gamepad ==="
# Upstream Batocera's libretroControllers.py only sets
# input_enable_hotkey_btn — the hotkey "enable" button — and never
# binds input_exit_emulator_btn / input_menu_toggle_btn /
# input_save_state_btn / input_load_state_btn. The keyboard-side
# bindings (escape = exit, f1 = menu) work fine but on a DualSense
# there's no way out of a game without sshing in and pkill'ing
# retroarch. Patch the function to also bind start/select/L1/R1.
PYFILE="$CHROOT/usr/lib/python3.12/site-packages/configgen/generators/libretro/libretroControllers.py"
if [ -f "$PYFILE" ]; then
    python3 - "$PYFILE" <<'PYPATCH'
import sys
p = sys.argv[1]
src = open(p).read()
old = "        retroconfig.save('input_enable_hotkey_btn', controllers[0].inputs['hotkey'].id)"
extra = '''
# PS5: map HOTKEY combos to gamepad — upstream sets only the
# enable button, leaving exit-emulator unbound on gamepad. Without
# this, gamepad users can't exit a retroarch game without sshing
# in and pkill'ing retroarch.
for batocera_key, retroarch_key in [
('start', 'input_exit_emulator_btn'),
('select', 'input_menu_toggle_btn'),
('pageup', 'input_load_state_btn'),
('pagedown', 'input_save_state_btn'),
]:
if batocera_key in controllers[0].inputs:
    retroconfig.save(retroarch_key, controllers[0].inputs[batocera_key].id)'''
if old in src and extra not in src:
    open(p, 'w').write(src.replace(old, old + extra))
    print('  patched libretroControllers.py')
else:
    print('  skipped (line not found or already patched)')
PYPATCH
else
    echo "  WARN: $PYFILE missing — configgen patch skipped"
fi

echo "=== Batocera: fstab + users ==="
# NOTE the FAT32 boot partition is mounted at /boot (not
# /boot/efi like the other distros) because batocera-part —
# which S11share uses to autodetect the SHARE partition by
# 'partition next to /boot' — greps /proc/mounts for /boot.
# If we mount at /boot/efi the SHARE auto-detection silently
# fails and S11share falls back to a 256 MB tmpfs at
# /userdata, which won't fit Steam / save data / anything.
# PS5 loader reads bzImage / cmdline.txt from the FAT32
# partition's root regardless of where Linux mounts it.
mkdir -p "$CHROOT/boot"
cat > "$CHROOT/etc/fstab" <<FSTAB
LABEL=$ROOT_LABEL / ext4 defaults 0 1
LABEL=$EFI_LABEL  /boot vfat defaults 0 1
LABEL=SHARE       /userdata ext4 defaults 0 2
FSTAB

echo "=== Batocera: first-boot SHARE partition creator ==="
# Batocera's design splits the disk into:
#   sda1 = rootfs (this image, ~15 GB)
#   sda2 = /boot FAT32
#   sda3 = /userdata SHARE (everything user-facing — games,
#           BIOS, Steam flatpak, screenshots, saves)
# The image only ships sda1+sda2. On first boot, expand the
# GPT backup header to the actual disk end (so parted/sgdisk
# see the full free space) then carve sda3 = SHARE out of
# the remainder. Self-disables after running.
cat > "$CHROOT/usr/local/sbin/ps5-share-init" <<'PS5SHARE'
#!/bin/sh
# First-boot: create the SHARE partition + fs if missing, so /userdata
# is a real disk-backed mount (916 GB on a 1 TB drive) instead of the
# 256 MB tmpfs fallback in /etc/init.d/S11share.
set -e
ROOT_DEV=$(findmnt -no SOURCE /)
DISK=$(/usr/bin/batocera-part prefix "$ROOT_DEV")
SHARE_NUM=$(/usr/bin/batocera-part share_internal_num)
SHARE_DEV="${DISK}${SHARE_NUM}"
[ -b "$DISK" ] || exit 0
# already created on a previous boot?
if [ -b "$SHARE_DEV" ] && blkid -L SHARE >/dev/null 2>&1; then
    exit 0
fi
echo "ps5-share-init: extending GPT + creating $SHARE_DEV"
sgdisk -e "$DISK"
partprobe "$DISK"
sleep 1
sgdisk -n "$SHARE_NUM":0:0 -c "$SHARE_NUM":share -t "$SHARE_NUM":8300 "$DISK"
partprobe "$DISK"
sleep 1
mkfs.ext4 -L SHARE -F "$SHARE_DEV"
PS5SHARE
chmod +x "$CHROOT/usr/local/sbin/ps5-share-init"
# Hook into Batocera's init order: run BEFORE S11share so
# S11share's batocera-part share_internal call finds the
# partition we just created.
cat > "$CHROOT/etc/init.d/S07ps5share" <<'INITSHARE'
#!/bin/sh
# First-boot SHARE partition creator — see /usr/local/sbin/ps5-share-init
case "$1" in
    start|"") /usr/local/sbin/ps5-share-init >> /tmp/ps5-share-init.log 2>&1 ;;
    stop|restart|reload|*) ;;
esac
INITSHARE
chmod +x "$CHROOT/etc/init.d/S07ps5share"

# First-boot defaults for /userdata/system/batocera.conf — set
# display.empty=1 so every system (PSP, PS1, PS2, PS3, PS4,
# Switch, etc) is visible in EmulationStation even before
# ROMs are loaded. S12 runs after S11share has populated
# /userdata. Idempotent: only sets a key if not already
# present, so the user remains free to flip it back.
cat > "$CHROOT/etc/init.d/S12ps5defaults" <<'INITDEF'
#!/bin/sh
case "$1" in
    start|"")
CONF=/userdata/system/batocera.conf
[ -f "$CONF" ] || exit 0
grep -qE '^display\.empty=' "$CONF" || echo 'display.empty=1' >> "$CONF"
;;
esac
INITDEF
chmod +x "$CHROOT/etc/init.d/S12ps5defaults"

# Batocera ships root passwordless. Leave root usable (a lot of
# Batocera scripts assume root) but ALSO add a ps5 user so the
# release-page convention works.
if ! grep -q "^ps5:" "$CHROOT/etc/passwd"; then
    echo "ps5:x:1000:1000:PS5:/home/ps5:/bin/sh" >> "$CHROOT/etc/passwd"
    echo "ps5:!::0:99999:7:::"                   >> "$CHROOT/etc/shadow"
    echo "ps5:x:1000:"                           >> "$CHROOT/etc/group"
    mkdir -p "$CHROOT/home/ps5"
    chroot "$CHROOT" /bin/sh -c "chown -R 1000:1000 /home/ps5" 2>/dev/null || true
fi
# Both root and ps5 get pw 'ps5' — Batocera's chpasswd is busybox.
chroot "$CHROOT" /bin/sh -c "printf 'ps5\nps5\n' | passwd ps5 2>/dev/null; printf 'ps5\nps5\n' | passwd root 2>/dev/null" || true

echo "=== Batocera: grow-rootfs first-boot service ==="
mkdir -p "$CHROOT/usr/local/sbin" "$CHROOT/etc/systemd/system"
cat > "$CHROOT/usr/local/sbin/grow-rootfs" <<'GROW'
#!/bin/sh
set -e
ROOT=$(findmnt -no SOURCE / || mount | awk '$3=="/"{print $1; exit}')
DISK=$(lsblk -no PKNAME "$ROOT" 2>/dev/null | head -1)
PARTNUM=$(echo "$ROOT" | grep -oE '[0-9]+$' || true)
[ -z "$DISK" ] || [ -z "$PARTNUM" ] && exit 0
growpart "/dev/$DISK" "$PARTNUM" || true
resize2fs "$ROOT" || true
GROW
chmod +x "$CHROOT/usr/local/sbin/grow-rootfs"
cat > "$CHROOT/etc/systemd/system/grow-rootfs.service" <<SVC
[Unit]
Description=Grow rootfs to fill disk (first boot)
ConditionPathExists=/usr/local/sbin/grow-rootfs
ConditionFirstBoot=yes
After=local-fs.target
Before=basic.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/grow-rootfs
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
SVC
# Batocera switched to systemd in v33+. Try systemctl enable;
# tolerate buildroot quirks where /etc/systemd/system layout
# differs.
mkdir -p "$CHROOT/etc/systemd/system/sysinit.target.wants"
ln -sf ../grow-rootfs.service \
    "$CHROOT/etc/systemd/system/sysinit.target.wants/grow-rootfs.service"
