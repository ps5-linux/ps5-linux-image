#!/bin/bash
# distros/steamos/build-rootfs.sh — fetch Valve's Steam Deck recovery image,
# extract its rootfs to $CHROOT, swap in our linux-ps5 kernel.  Called from
# docker/image-builder/entrypoint.sh for DISTRO=steamos.
#
# SteamOS 3 (Holo, Arch-based) ships as a single .img.bz2 with multiple
# partitions: A/B rootfs (btrfs on recovery, erofs on production), A/B
# var (ext4), an EFI partition, and a home partition. We take the
# rootfs-A + var-A slots, copy them flat to $CHROOT, then drop in our
# linux-ps5 kernel pkg.tar.zst and rebuild the initramfs with the
# modules amdgpu actually needs to bring up the PS5 Oberon GPU.
#
# Expects in env: DISTRO, CHROOT, KVER, ROOT_LABEL, EFI_LABEL
# Expects on disk: /kernel-debs/linux-ps5-*.pkg.tar.zst,
#                  /repo/distros/steamos/{return-to-gaming-mode.desktop,
#                                        steam-session-switch-listener.{py,service}},
#                  /repo/distros/arch/{grow-rootfs,grow-rootfs.service}

set -ex

: "${CHROOT:?ERROR: \$CHROOT unset/empty}"
[ -d "$CHROOT" ] || { echo "ERROR: \$CHROOT=$CHROOT not a directory"; exit 2; }
case "$CHROOT" in /) echo "ERROR: refuse to operate on /"; exit 2 ;; esac

STEAMOS_URL="${STEAMOS_URL:-https://steamdeck-images.steamos.cloud/recovery/steamdeck-repair-latest.img.bz2}"

echo "=== SteamOS: resolve latest image URL ==="
# python3 is in the upstream image-builder Dockerfile; curl isn't.
RESOLVED_URL=$(python3 -c "import urllib.request; print(urllib.request.urlopen('$STEAMOS_URL').geturl())")
IMG_NAME=$(basename "$RESOLVED_URL")
echo ">> resolved $IMG_NAME"

CACHED="/build/cache/$IMG_NAME"
if [ ! -s "$CACHED" ]; then
    echo ">> downloading $IMG_NAME (~3.4 GB from Valve CDN)"
    wget --tries=3 -O "$CACHED.part" "$RESOLVED_URL"
    mv "$CACHED.part" "$CACHED"
fi
echo ">> using $CACHED ($(du -h "$CACHED" | cut -f1))"

echo "=== SteamOS: decompress + loop ==="
STEAMOS_IMG=/build/steamos-src.img
bunzip2 -kc "$CACHED" > "$STEAMOS_IMG"
SLOOP=$(losetup -Pf --show "$STEAMOS_IMG")
sleep 1
# kpartx fallback when loopNpX devices didn't appear under /dev/
if [ ! -e "${SLOOP}p1" ]; then
    kpartx -av "$SLOOP"
    sleep 1
fi
# Build candidate partition list — either /dev/loopNpX or
# /dev/mapper/loopNpX depending on how kpartx mapped them.
SLOOP_BASE=$(basename "$SLOOP")
PART_PATHS=()
for cand in "${SLOOP}"p* "/dev/mapper/${SLOOP_BASE}"p*; do
    [ -e "$cand" ] && PART_PATHS+=("$cand")
done

# The RECOVERY image uses btrfs for the rootfs (production
# SteamOS uses erofs A/B; recovery needs writes so it's btrfs).
# Take the first btrfs partition; that's rootfs. Fall back to
# erofs in case Valve ever changes it.
SROOT=""
SROOT_FS=""
for fstype in btrfs erofs; do
    for p in "${PART_PATHS[@]}"; do
        t=$(blkid -o value -s TYPE "$p" 2>/dev/null || echo "")
        if [ "$t" = "$fstype" ]; then
            SROOT="$p"; SROOT_FS="$fstype"; break 2
        fi
    done
done
if [ -z "$SROOT" ]; then
    echo "ERROR: no btrfs/erofs rootfs in SteamOS image. partitions seen:"
    for p in "${PART_PATHS[@]}"; do
        echo "  $p  type=$(blkid -o value -s TYPE "$p" 2>/dev/null) size=$(blockdev --getsize64 "$p" 2>/dev/null)"
    done
    exit 1
fi
echo ">> rootfs slot: $SROOT ($SROOT_FS)"

SMNT=$(mktemp -d)
mount -t "$SROOT_FS" -o ro "$SROOT" "$SMNT"

# If btrfs, look for SteamOS's @rootfs subvolume — the top-level
# btrfs view may be empty / hold only subvol entries, in which
# case we need to remount with subvol=@rootfs (or @, depending
# on the image's layout).
if [ "$SROOT_FS" = "btrfs" ] && [ ! -d "$SMNT/usr" ]; then
    echo ">> top-level btrfs has no /usr; scanning subvolumes"
    btrfs subvolume list "$SMNT" 2>&1 | head -20 || true
    umount "$SMNT"
    for sub in @rootfs @ rootfs root; do
        if mount -t btrfs -o "ro,subvol=$sub" "$SROOT" "$SMNT" 2>/dev/null; then
            if [ -d "$SMNT/usr" ]; then
                echo ">> rootfs at subvol=$sub"
                break
            fi
            umount "$SMNT"
        fi
    done
    if [ ! -d "$SMNT/usr" ]; then
        echo "ERROR: couldn't locate rootfs in btrfs at any known subvol"
        exit 1
    fi
fi
echo "=== SteamOS: copy rootfs ($(du -sh "$SMNT" | cut -f1)) -> \$CHROOT ==="
cp -a "$SMNT"/. "$CHROOT/"
umount "$SMNT"
rmdir "$SMNT"

# SteamOS splits /var off the rootfs onto its own partition.
# First-boot fails without /var/lib/dbus etc.
VARMNT=$(mktemp -d)
for p in "${PART_PATHS[@]}"; do
    t=$(blkid -o value -s TYPE "$p" 2>/dev/null || echo "")
    sz=$(blockdev --getsize64 "$p" 2>/dev/null || echo 0)
    if [ "$t" = "ext4" ] && [ "$sz" -lt $((2 * 1024 * 1024 * 1024)) ]; then
        if mount -o ro "$p" "$VARMNT" 2>/dev/null; then
            if [ -d "$VARMNT/lib" ] || [ -d "$VARMNT/log" ]; then
                echo "=== SteamOS: copy var ($(du -sh "$VARMNT" | cut -f1)) -> \$CHROOT/var ==="
                mkdir -p "$CHROOT/var"
                cp -a "$VARMNT"/. "$CHROOT/var/" || true
                umount "$VARMNT"
                break
            fi
            umount "$VARMNT" 2>/dev/null || true
        fi
    fi
done
rmdir "$VARMNT"

kpartx -dv "$SLOOP" 2>/dev/null || true
losetup -d "$SLOOP"
rm -f "$STEAMOS_IMG"

echo "=== SteamOS: install linux-ps5 kernel pkg ==="
PKG=$(ls /kernel-debs/linux-ps5-*.pkg.tar.zst 2>/dev/null | head -1)
[ -z "$PKG" ] && { echo "ERROR: no linux-ps5 pkg.tar.zst in /kernel-debs/"; exit 1; }
TMP=$(mktemp -d)
bsdtar -xf "$PKG" -C "$TMP"
for d in usr boot etc; do
    [ -d "$TMP/$d" ] && cp -a "$TMP/$d"/. "$CHROOT/$d/" 2>/dev/null || true
done
rm -rf "$TMP"

# Redetect KVER from the installed module dir — the entrypoint's
# top-level detect_kver pulls a bare semver like '7.0.10' out of the
# pkg filename, but the linux-ps5 pkg actually installs modules under
# something like '7.0.10-ps5' (with a localversion suffix). Use what's
# actually on disk so depmod / mkinitramfs find the modules.
KVER=$(ls -1 "$CHROOT/usr/lib/modules" 2>/dev/null \
    | grep -v "$(ls -1 "$CHROOT/usr/lib/modules" 2>/dev/null \
                 | grep -E 'neptune|^[0-9]+\.[0-9]+\.[0-9]+-[^-]+$' \
                 | grep -v 'ps5' || true)" | head -1)
[ -z "$KVER" ] && KVER=$(ls -1 "$CHROOT/usr/lib/modules" 2>/dev/null | grep ps5 | head -1)
[ -z "$KVER" ] && KVER=$(ls -1 "$CHROOT/usr/lib/modules" 2>/dev/null | head -1)
echo ">> KVER=$KVER"

# Drop SteamOS's own kernel(s) so grub boots ours
rm -f "$CHROOT"/boot/vmlinuz-linux* "$CHROOT"/boot/initrd*-neptune* \
      "$CHROOT"/boot/initramfs-linux*.img 2>/dev/null || true
for d in "$CHROOT"/usr/lib/modules/*; do
    [ -d "$d" ] || continue
    [ "$(basename "$d")" = "$KVER" ] && continue
    rm -rf "$d"
done

if [ -x "$CHROOT/usr/bin/depmod" ]; then
    chroot "$CHROOT" /usr/bin/depmod -a "$KVER" || true
else
    depmod -b "$CHROOT" "$KVER" || true
fi

[ -f "$CHROOT/boot/vmlinuz-$KVER" ] || \
    cp "$CHROOT"/boot/vmlinuz-* "$CHROOT/boot/vmlinuz-$KVER" 2>/dev/null || true
mkdir -p "$CHROOT/boot/efi"
cp "$CHROOT/boot/vmlinuz-$KVER" "$CHROOT/boot/efi/bzImage" 2>/dev/null || true

# Symlink chroot's modules into host /lib/modules so the build
# container's mkinitramfs/depmod can see them. PS5 kernel pkg
# installs modules under /usr/lib/modules.
echo "=== SteamOS: build initrd via host mkinitramfs ==="
mkdir -p /lib/modules
ln -sfn "$CHROOT/usr/lib/modules/$KVER" "/lib/modules/$KVER"

cat > /etc/initramfs-tools/modules <<'INITMODS'
# USB host controllers (PS5 boot drive is USB 3 — xhci must be present).
xhci_pci
xhci_hcd
ehci_pci
ehci_hcd
ohci_pci
ohci_hcd
# Storage
usb-storage
uas
# Filesystems we may root on
ext4
btrfs
vfat
# Block stack
sd_mod
loop
dm_mod
# AMD GPU + display for early framebuffer
amdgpu
INITMODS

# Force MODULES=most so we include everything for the PS5
# regardless of what's loaded in the build container.
sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf

# amdgpu options for the PS5 Oberon GPU: dpm=0 keeps HDMI alive
# (DPM transitions stall the DP→HDMI bridge into a stuck-low
# state, displayed as a black screen the moment KWin tries to
# take DRM master from gamescope — exact symptom: 'failed to
# display topology' in Plasma + black screen with cursor after
# Switch-to-Desktop). gpu_recovery=0 avoids the linux-ps5
# patched recovery path that hard-faults on Oberon. Bazzite
# already ships these for the same reason.
#
# Land in both initramfs and rootfs so amdgpu picks them up at
# both probe times (early initramfs phase + post-switch_root).
mkdir -p "$CHROOT/etc/modprobe.d" /etc/modprobe.d
cat > "$CHROOT/etc/modprobe.d/ps5-amdgpu.conf" <<'AMDGPU'
options amdgpu dpm=0 gpu_recovery=0
AMDGPU
cp "$CHROOT/etc/modprobe.d/ps5-amdgpu.conf" /etc/modprobe.d/ps5-amdgpu.conf

mkinitramfs -k "$KVER" -o "$CHROOT/boot/efi/initrd.img"
# Also drop a copy at the standard location inside the rootfs.
cp "$CHROOT/boot/efi/initrd.img" "$CHROOT/boot/initramfs-$KVER.img"

rm -f "/lib/modules/$KVER"

# SteamOS recovery image ships without a default.target symlink and
# relies on the cmdline to set systemd.unit=. Without either,
# systemd hangs at "solid cursor on tty1" forever. Fix both so
# either path reaches graphical.target.
ln -sf /usr/lib/systemd/system/graphical.target "$CHROOT/etc/systemd/system/default.target"

# sshd: recovery image ships it disabled. We want it on by
# default so we can ssh in from the LAN without poking the
# console. Enable + set deck's password to 'deck' (matches
# the build-time convention used for the other distros).
mkdir -p "$CHROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/sshd.service \
    "$CHROOT/etc/systemd/system/multi-user.target.wants/sshd.service"
chroot "$CHROOT" /usr/bin/bash -c 'echo "deck:deck" | chpasswd' 2>/dev/null || \
    chroot "$CHROOT" /bin/sh -c 'echo "deck:deck" | chpasswd' 2>/dev/null || true
# also unlock the account in case it's locked
chroot "$CHROOT" /usr/bin/passwd -u deck 2>/dev/null || true

# Enable sddm. The recovery image ships sddm.service in
# /usr/lib/systemd/system but NEVER symlinks it into
# graphical.target.wants — relies on a first-boot Valve setup
# script that we've cut out. Without this, graphical.target
# is reached but no display manager starts → black screen
# even with working GPU init.
mkdir -p "$CHROOT/etc/systemd/system/graphical.target.wants"
ln -sf /usr/lib/systemd/system/sddm.service \
    "$CHROOT/etc/systemd/system/graphical.target.wants/sddm.service"

# Switch-to-Desktop / Return-to-Gaming buttons: gamescope/Steam
# and steamos-manager may invoke a session named literally
# "desktop" or "gamescope" (bare aliases) — those land both in
# SDDM's session lookup AND in our steamos-session-select shim
# below. Add symlinks so the SDDM lookup path resolves, and
# match the same naming below in the shim's case statement.
ln -sfn plasma.desktop             "$CHROOT/usr/share/wayland-sessions/desktop.desktop"
ln -sfn plasmax11.desktop          "$CHROOT/usr/share/xsessions/desktop.desktop"
ln -sfn gamescope-wayland.desktop  "$CHROOT/usr/share/wayland-sessions/gamescope.desktop"

# AMD GPU firmware comes from the SteamOS rootfs as .bin.zst
# (zstd-compressed). Our linux-ps5 7.0.10 kernel is built
# WITHOUT CONFIG_FW_LOADER_COMPRESS_ZSTD=y so the kernel's
# firmware loader looks for the bare .bin only, fails -2,
# amdgpu logs "Fatal error during GPU init", no display.
# Decompress every firmware blob in place; keep the .zst
# alongside (cheap, harmless) so the kernel finds the .bin
# without us having to enumerate which specific blobs amdgpu
# asks for on this revision (currently pfp + sdma; could
# grow). Side benefit: covers wifi/bluetooth/etc firmware
# for free.
echo "=== SteamOS: decompress *.bin.zst firmware (kernel can't load compressed) ==="
fw_count=0
while IFS= read -r -d '' zst; do
    out="${zst%.zst}"
    if [ ! -e "$out" ]; then
        zstd -dq -o "$out" "$zst" && fw_count=$((fw_count+1))
    fi
done < <(find "$CHROOT/lib/firmware" "$CHROOT/usr/lib/firmware" \
              -name '*.bin.zst' -print0 2>/dev/null)
echo ">> decompressed $fw_count firmware files"

# mkinitramfs runs BEFORE this point in the script and bakes
# the amdgpu module into the initramfs (per our modules list).
# But Debian's mkinitramfs does NOT copy /lib/firmware/* into
# the initramfs by default — so when amdgpu probes in early
# userspace (initramfs phase, before switch_root), it requests
# firmware from initramfs's /lib/firmware/ which doesn't have
# it → ENOENT → fatal GPU init → no display, identical
# symptom to the .zst-only-firmware bug above. Inject the
# decompressed amdgpu blobs INTO the initrd image now (it's
# a zstd cpio newc archive — extract, add, repack).
INITRD="$CHROOT/boot/efi/initrd.img"
if [ -f "$INITRD" ] && [ -d "$CHROOT/lib/firmware/amdgpu" ]; then
    echo "=== SteamOS: inject amdgpu firmware into initramfs ==="
    IWORK=$(mktemp -d)
    ( cd "$IWORK" && zstd -dc "$INITRD" | cpio -idmu --quiet --no-absolute-filenames )
    mkdir -p "$IWORK/usr/lib/firmware/amdgpu"
    cp "$CHROOT/lib/firmware/amdgpu"/*.bin "$IWORK/usr/lib/firmware/amdgpu/" 2>/dev/null || true
    # Some kernels probe /lib/firmware first, some /usr/lib/firmware.
    # Make both reachable.
    ln -sfn usr/lib/firmware "$IWORK/lib/firmware" 2>/dev/null || true
    ( cd "$IWORK" && find . | cpio -o -H newc --quiet | zstd -19 --quiet ) > "$INITRD.new"
    mv "$INITRD.new" "$INITRD"
    cp "$INITRD" "$CHROOT/boot/initramfs-$KVER.img"
    rm -rf "$IWORK"
    echo ">> initramfs repacked with firmware ($(du -h "$INITRD" | cut -f1))"
fi

# Persistent journal so post-boot failures are debuggable from
# outside (read it by mounting the rootfs). Needs the
# systemd-journal group ownership + setgid bit or journald
# refuses to use it and silently stays volatile.
mkdir -p "$CHROOT/var/log/journal"
chown 0:980 "$CHROOT/var/log/journal" 2>/dev/null || \
    chroot "$CHROOT" chown 0:systemd-journal /var/log/journal 2>/dev/null || true
chmod 2755 "$CHROOT/var/log/journal"

# SteamOS fstab references its A/B atomic partset paths
# (/dev/disk/by-partsets/{self,shared}/...) which don't exist
# on a flat-rootfs flash — every mount unit fails and stalls
# local-fs.target dependencies (NetworkManager etc.).
sed -i '/by-partsets/s|^|#FLAT-ROOTFS-DISABLED# |' "$CHROOT/etc/fstab"

# …but we still need /efi mounted at boot. ps5-stage-firmware
# reads the NXP IW620 WLAN blob from /boot/efi/lib/nxp/, and
# cmdline.txt / kexec.sh / bzImage live there too. Append a
# label-based mount line so the FAT boot partition is up
# before sysinit.target. /boot/efi is a symlink to /efi in
# the recovery image; mount the canonical target.
cat >> "$CHROOT/etc/fstab" <<FSTAB
LABEL=$EFI_LABEL /efi vfat defaults,nofail,umask=0077 0 2
FSTAB

# steamos-customizations also ships explicit .mount units for
# esp/efi/home that pull in partset-aware fsck + blockdev
# targets. Mask esp.mount + home.mount (we don't have those
# partitions), but leave efi.mount alone — it'd race the
# fstab line above. systemd just generates a fresh efi.mount
# from our fstab entry.
for u in esp.mount home.mount; do
    ln -sf /dev/null "$CHROOT/etc/systemd/system/$u"
done

# The recovery image ships /etc/sddm.conf.d/zz-steamos-autologin.conf
# with Session=plasma — it's normally written when a Deck user
# picks "Switch to Desktop" from Steam, but the recovery image
# bakes it in pre-set to KDE. With it present, SDDM autologs
# into Plasma instead of the gamescope-wayland session.
#
# Just `rm` isn't enough: on first boot ps5-gamescope-recovery
# (or steam-jupiter falling back to KDE because gamescope can't
# grab a display) writes this file back with Session=plasma,
# and we land in Plasma on every subsequent boot too.
# Overwrite with gamescope-wayland.desktop so even when the
# file gets recreated by Steam/recovery, we still autologin
# into Big Picture.
mkdir -p "$CHROOT/etc/sddm.conf.d"
cat > "$CHROOT/etc/sddm.conf.d/zz-steamos-autologin.conf" <<'EOF'
[Autologin]
Session=gamescope-wayland.desktop
EOF

# Replace /usr/bin/steamos-session-select with a dumb shim that
# writes the sddm autologin file directly + restarts sddm. The
# vendored version delegates to steamosctl/steamos-manager whose
# Steam Deck hardware code paths silently no-op on PS5 — the
# symptom is "Return to Gaming Mode just reloads Desktop" because
# the autologin Session= never actually changes. This shim bypasses
# the whole DBus dance.
if [ -f "$CHROOT/usr/bin/steamos-session-select" ]; then
    mv "$CHROOT/usr/bin/steamos-session-select" \
       "$CHROOT/usr/bin/steamos-session-select.orig"
    cat > "$CHROOT/usr/bin/steamos-session-select" <<'SHIM'
#!/bin/bash
# PS5-flat-rootfs shim: write a sddm autologin override directly +
# restart sddm. Bypasses the vendored script that delegates to
# steamosctl/steamos-manager (which silently no-ops on PS5).
#
# Uses sudo (deck has passwordless sudo on this build) rather than
# the recovery image's pkexec → steamos-priv-write path: that helper
# only whitelists /sys/class/backlight and similar paths, NOT
# /etc/sddm.conf.d, so any pkexec write attempt fails with an
# unbound-variable error from the priv-write script. Sudo is simpler
# and works from any context (Konsole, desktop shortcut, even SSH).
#
# Conf filename 'zzz-session-override.conf':
#   * sorts AFTER zz-steamos-autologin.conf so this file wins precedence
#   * does NOT match sddm's ExecStartPre 'rm /etc/sddm.conf.d/zzt-...'
#     drop-in pattern, so the override survives systemctl restart sddm
set -e
session="${1:-gamescope}"
case "$session" in
    plasma-wayland|plasma-wayland-persistent)  target="plasma.desktop"            ;;
    plasma|plasma-x11|plasma-x11-persistent)   target="plasmax11.desktop"         ;;
    desktop)                                   target="plasma.desktop"            ;;
    gamescope)                                 target="gamescope-wayland.desktop" ;;
    *)                                         target="gamescope-wayland.desktop" ;;
esac
sudo tee /etc/sddm.conf.d/zzz-session-override.conf >/dev/null <<EOF
[Autologin]
User=deck
Session=$target
Relogin=true
EOF
sudo systemctl restart sddm
SHIM
    chmod 755 "$CHROOT/usr/bin/steamos-session-select"
fi

# Steam Big Picture's Power-Menu "Switch to Desktop" button
# fires a dbus call:
#     dbus-send --system --dest=org.freedesktop.DisplayManager \
#         /org/freedesktop/DisplayManager/Seat0 \
#         org.freedesktop.DisplayManager.Seat.SwitchToUser \
#         string:doorstop string:<session>
# On the real Steam Deck this lands in Valve's patched SDDM
# which writes /etc/sddm.conf.d/zzt-steamos-temp-login.conf.
# Stock Arch SDDM (what the recovery image ships) accepts the
# call but does nothing useful with it — the button is a no-op,
# and re-adding -steamos3 to the Steam launcher to route the
# button through our shim triggers Steam's A/B atomic-update
# reboot loop.
#
# Workaround: a tiny daemon that BecomeMonitor()s the system
# bus, catches the SwitchToUser call, and runs the same
# zzz-session-override.conf write + sddm restart that our shim
# does. Steam's button now works without the -steamos3 flag.
mkdir -p "$CHROOT/usr/local/sbin" "$CHROOT/etc/systemd/system"
install -m 755 /repo/distros/steamos/steam-session-switch-listener.py \
    "$CHROOT/usr/local/sbin/steam-session-switch-listener" 2>/dev/null \
    || cp /repo/distros/steamos/steam-session-switch-listener.py \
          "$CHROOT/usr/local/sbin/steam-session-switch-listener"
chmod +x "$CHROOT/usr/local/sbin/steam-session-switch-listener"
cp /repo/distros/steamos/steam-session-switch-listener.service \
    "$CHROOT/etc/systemd/system/steam-session-switch-listener.service"
mkdir -p "$CHROOT/etc/systemd/system/multi-user.target.wants"
ln -sf ../steam-session-switch-listener.service \
    "$CHROOT/etc/systemd/system/multi-user.target.wants/steam-session-switch-listener.service"

# Replace the recovery image's broken Return.desktop. The vendor
# shortcut delegates to steamosctl, which silently no-ops on
# PS5. Ours calls steamos-session-select gamescope directly
# (our shim above does the real work). Drop it on deck's
# Desktop AND in /usr/share/applications so it's discoverable
# from the app menu too.
mkdir -p "$CHROOT/home/deck/Desktop" "$CHROOT/usr/share/applications"
cp /repo/distros/steamos/return-to-gaming-mode.desktop \
    "$CHROOT/home/deck/Desktop/Return.desktop"
cp /repo/distros/steamos/return-to-gaming-mode.desktop \
    "$CHROOT/usr/share/applications/return-to-gaming-mode.desktop"
chmod 755 "$CHROOT/home/deck/Desktop/Return.desktop"

# The recovery image ships /home/deck owned by root:root (the
# vendor install flow chowns it later during first-boot OOBE,
# which we've masked out). Without this fix, KDE Plasma fails
# to create /home/deck/.config on first login — error popup:
# "Configuration file /home/deck/.config/kcminitrc not writable.
# Please contact your system administrator."
# Chown the whole tree to deck:deck (uid/gid 1000) so Plasma
# init can write its caches/configs.
chroot "$CHROOT" chown -R deck:deck /home/deck 2>/dev/null || \
    chown -R 1000:1000 "$CHROOT/home/deck"

# The recovery image's pacman trust DB is populated for
# archlinux only — not the holo (SteamOS Valve CI) keys —
# so `pacman -Syu` on first boot fails every package with
# "unknown trust" from the GitLab CI Package Builder key.
# The holo-keyring package IS installed; just needs --populate.
chroot "$CHROOT" pacman-key --init 2>/dev/null || true
chroot "$CHROOT" pacman-key --populate holo 2>/dev/null || true

# First-boot rootfs grow. Reuses the arch distro's grow-rootfs +
# service (same Arch-userland recipe — growpart + resize2fs at
# boot). Our build pins a fixed-size rootfs (~14 GB); the user
# flashes onto multi-hundred-GB USB drives. Without this, sda1
# stays 11 GB and Steam/flatpak run out of space within an hour.
install -m 755 /repo/distros/arch/grow-rootfs \
    "$CHROOT/usr/local/sbin/grow-rootfs"
install -m 644 /repo/distros/arch/grow-rootfs.service \
    "$CHROOT/etc/systemd/system/grow-rootfs.service"
mkdir -p "$CHROOT/etc/systemd/system/local-fs.target.wants"
ln -sf ../grow-rootfs.service \
    "$CHROOT/etc/systemd/system/local-fs.target.wants/grow-rootfs.service"

# Disable the atomic OS updater. The Steam UI calls
# /usr/bin/steamos-update on session start, which tries to
# apply Valve's A/B atomic OTA via partsets we don't have +
# neptune kernel != our linux-ps5. Result: "Unable to
# download the required update" nag every session. Replace
# with a noop that returns "no update available" (exit 7)
# while honoring the --supports-duplicate-detection probe.
if [ -f "$CHROOT/usr/bin/steamos-update" ]; then
    mv "$CHROOT/usr/bin/steamos-update" "$CHROOT/usr/bin/steamos-update.orig"
    cat > "$CHROOT/usr/bin/steamos-update" <<'SHIM'
#!/bin/bash
# Disabled — flat-rootfs PS5 build can't apply SteamOS A/B atomic OTAs.
if [ "$1" = "--supports-duplicate-detection" ]; then
    echo "supports duplicate detection" >&2
    exit 0
fi
echo "No update available (disabled — flat-rootfs PS5 build)" >&2
exit 7
SHIM
    chmod 755 "$CHROOT/usr/bin/steamos-update"
fi

# Even with steamos-update shimmed, the Steam Big Picture UI
# downloads the OS update tarball directly from
# update.steamos.cloud and calls steamos-reboot --reboot-other
# to apply it. --reboot-other is Valve's "switch active A/B
# partset slot then reboot" — since we have no partsets it
# just reboots into the same image, Steam sees the update
# still pending, downloads again, reboots. Infinite loop.
# Shim steamos-reboot so --reboot-other is a silent noop;
# plain reboot still works.
# Strip -steamos3 + -steampal from the gamescope-session launcher.
# These two flags are what makes the Steam client believe it's
# running on a real Deck with the A/B atomic update model, so
# after every bootstrap download Steam calls logind.Reboot to
# "apply" the update — on a flat-rootfs build the reboot does
# nothing and we just come back to the same image, loop forever.
# Keep -steamdeck (Big Picture UI fidelity) and -gamepadui
# (gamepad-driven UI). Also tack on -noverifyfiles so the
# 493 MB client redownload doesn't repeat every session.
sed -i 's|^steamargs=("-steamos3" "-steampal" "-steamdeck" "-gamepadui")|steamargs=("-steamdeck" "-gamepadui" "-noverifyfiles")|' \
    "$CHROOT/usr/lib/steamos/steam-launcher" 2>/dev/null || true

# /usr/bin/steam → /usr/bin/steam-jupiter (symlink). The
# steam-jupiter wrapper is Valve's OOBE script that does
# `rm -rf ~/.steam ~/.local/share/Steam` at the top of every
# launch — because the recovery image is meant to live as a
# single-shot first-boot installer and the A/B atomic system
# handles persistence. On our flat-rootfs build that wipe is
# the cause of the "Steam downloads ~493 MB every session"
# loop. Replace with one that just execs the real Steam
# binary with the deck flags.
if [ -f "$CHROOT/usr/bin/steam-jupiter" ]; then
    mv "$CHROOT/usr/bin/steam-jupiter" "$CHROOT/usr/bin/steam-jupiter.orig"
    cat > "$CHROOT/usr/bin/steam-jupiter" <<'SHIM'
#!/bin/bash
# Patched for flat-rootfs PS5 build:
# - skip OOBE rm -rf so Steam state persists across the reboot Steam
#   would otherwise fire post-bootstrap
# - drop -steamdeck so this desktop entry doesn't trigger the Deck-
#   specific reboot-to-apply update path either. Gaming Mode entry
#   path keeps its UI flags via /usr/lib/steamos/steam-launcher.
set -euo pipefail
exec /usr/lib/steam/steam -skipinitialbootstrap "$@"
SHIM
    chmod 755 "$CHROOT/usr/bin/steam-jupiter"
fi

# Steam binary calls logind.Reboot via DBus directly after the
# bootstrap finishes downloading (its "apply the update by
# rebooting" flow that assumes Deck-style A/B atomic). The
# reboot happens BEFORE the bootstrap can mark itself
# complete, so next boot Steam still thinks installed=0 and
# re-downloads — loop. Block reboot/power-off from the deck
# user via polkit so Steam can't trigger it. Manual reboots
# via SSH/Konsole as root still work.
mkdir -p "$CHROOT/etc/polkit-1/rules.d"
cat > "$CHROOT/etc/polkit-1/rules.d/05-disable-deck-reboot.rules" <<'PK'
// Block Steam (running as deck) from issuing reboot/poweroff via DBus.
// On a real Steam Deck the A/B atomic update model wants Steam to be
// able to "reboot to apply" — here it traps us in a download loop
// because nothing actually applies. Manual reboots still work as root
// (sudo reboot via SSH or Konsole in Desktop Mode).
polkit.addRule(function(action, subject) {
    if (subject.user === "deck" && (
        action.id === "org.freedesktop.login1.reboot" ||
        action.id === "org.freedesktop.login1.reboot-multiple-sessions" ||
        action.id === "org.freedesktop.login1.power-off" ||
        action.id === "org.freedesktop.login1.power-off-multiple-sessions" ||
        action.id === "org.freedesktop.login1.set-reboot-to-firmware-setup"
    )) {
        return polkit.Result.NO;
    }
});
PK
chmod 644 "$CHROOT/etc/polkit-1/rules.d/05-disable-deck-reboot.rules"

if [ -f "$CHROOT/usr/bin/steamos-reboot" ]; then
    mv "$CHROOT/usr/bin/steamos-reboot" "$CHROOT/usr/bin/steamos-reboot.orig"
    cat > "$CHROOT/usr/bin/steamos-reboot" <<'SHIM'
#!/bin/bash
# Shimmed for flat-rootfs PS5 build — no A/B partsets, so --reboot-other
# (Steam OS-update apply path) restarts SDDM instead of doing the A/B
# slot switch + reboot. Gamescope-session relaunches cleanly into Steam
# login. Plain reboot still works.
case "${1:-}" in
    --reboot-other)
        # Clear pending atomupd state so Steam does not immediately
        # re-prompt for the same "update" on the next session.
        rm -rf /var/lib/steamos-atomupd/.cache \
               /home/.steamos/offload/var/lib/steamos-atomupd/.cache \
               2>/dev/null || true
        echo "steamos-reboot: --reboot-other -> sddm restart (no A/B partsets)" >&2
        systemctl restart sddm
        exit 0
        ;;
    *)
        exec /sbin/reboot "$@"
        ;;
esac
SHIM
    chmod 755 "$CHROOT/usr/bin/steamos-reboot"
fi

# FINAL OVERRIDE — the earlier zz-steamos-autologin.conf write
# isn't sticking on the flashed image (file shows the recovery image's
# stock mtime / Session=plasma after boot). Something between that
# write and the partition copy in the standard image-builder flow is
# overlaying it back. Last-write-wins: redo it here at the end of the
# script, and ALSO drop a sentinel zzz-session-override.conf that
# sorts even later — same one our shim writes — so SDDM merge order
# absolutely lands on gamescope-wayland for first boot.
mkdir -p "$CHROOT/etc/sddm.conf.d"
cat > "$CHROOT/etc/sddm.conf.d/zz-steamos-autologin.conf" <<'AUTOLOGIN_END'
[Autologin]
Session=gamescope-wayland.desktop
AUTOLOGIN_END
cat > "$CHROOT/etc/sddm.conf.d/zzz-session-override.conf" <<'OVERRIDE_END'
[Autologin]
User=deck
Session=gamescope-wayland.desktop
Relogin=true
OVERRIDE_END
echo "=== verify autologin file content ==="
ls -la "$CHROOT/etc/sddm.conf.d/"
grep -H Session= "$CHROOT/etc/sddm.conf.d/"*.conf || true

echo "=== SteamOS: rootfs prepared at \$CHROOT ($(du -sh "$CHROOT" | cut -f1)), initrd $(du -h "$CHROOT/boot/efi/initrd.img" | cut -f1) ==="
