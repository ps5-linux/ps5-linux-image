#!/bin/bash
# distros/bazzite/build-rootfs.sh — fetch the uBlue OCI image and prep $CHROOT.
# Called from docker/image-builder/entrypoint.sh for DISTRO=bazzite*.
#
# Bazzite is an OCI atomic image; we bypass distrobuilder entirely.
#   DISTRO=bazzite      -> ghcr.io/ublue-os/bazzite:stable
#   DISTRO=bazzite-deck -> ghcr.io/ublue-os/bazzite-deck:stable
#
# Expects in env: DISTRO, CHROOT, KVER
# Expects on disk: /kernel-debs/*.rpm (linux-ps5 RPM), /repo/distros/bazzite/{grow-rootfs,grow-rootfs.service}

set -ex

: "${CHROOT:?ERROR: \$CHROOT unset/empty}"
[ -d "$CHROOT" ] || { echo "ERROR: \$CHROOT=$CHROOT not a directory"; exit 2; }
case "$CHROOT" in /) echo "ERROR: refuse to operate on /"; exit 2 ;; esac

# Bazzite is an OCI atomic image; bypass distrobuilder entirely.
# DISTRO=bazzite      -> ghcr.io/ublue-os/bazzite:stable
# DISTRO=bazzite-deck -> ghcr.io/ublue-os/bazzite-deck:stable
# Anything else after `bazzite-` is treated as the same uBlue
# image-name pattern (bazzite-gnome, bazzite-nvidia, ...).
case "$DISTRO" in
    bazzite)      REF="ghcr.io/ublue-os/bazzite:stable" ;;
    bazzite-*)    REF="ghcr.io/ublue-os/${DISTRO}:stable" ;;
    *)            REF="ghcr.io/ublue-os/bazzite:stable" ;;
esac
echo "=== Bazzite: skopeo copy $REF ==="
OCI=$(mktemp -d)
skopeo copy --override-os linux --override-arch amd64 \
    "docker://$REF" "oci:$OCI:bazzite"
echo "=== umoci unpack -> $CHROOT ==="
UNPACK=$(mktemp -d)
umoci unpack --keep-dirlinks --image "$OCI:bazzite" "$UNPACK"
# umoci layout: $UNPACK/{config.json, rootfs/}
mv "$UNPACK/rootfs"/* "$CHROOT/" 2>/dev/null || true
mv "$UNPACK/rootfs"/.[!.]* "$CHROOT/" 2>/dev/null || true
rm -rf "$UNPACK" "$OCI"
# ostree convention: /usr/etc holds the defaults; /etc is empty in
# the image. Promote /usr/etc to /etc so the system boots normally.
if [ -d "$CHROOT/usr/etc" ]; then
    cp -an "$CHROOT/usr/etc/." "$CHROOT/etc/" || true
    rm -rf "$CHROOT/usr/etc"
fi
# Stage PS5 kernel RPMs + grow-rootfs. /opt and /home are ostree
# symlinks in Bazzite, /var is a real dir — drop staging files there.
mkdir -p "$CHROOT/var/cache/ps5-rpms"
cp /kernel-debs/*.rpm "$CHROOT/var/cache/ps5-rpms/"
# /usr/local is a symlink to /var/usrlocal in ostree-based systems;
# mkdir the target before cp to avoid following-symlink-on-missing.
mkdir -p "$CHROOT/var/usrlocal/sbin"
cp /repo/distros/bazzite/grow-rootfs       "$CHROOT/var/usrlocal/sbin/grow-rootfs"
chmod +x "$CHROOT/var/usrlocal/sbin/grow-rootfs"
cp /repo/distros/bazzite/grow-rootfs.service "$CHROOT/etc/systemd/system/grow-rootfs.service"
# Chroot in: disable ostree stack, install PS5 kernel, user setup.
# Trap to always umount, even if the chroot script exits early.
cleanup_bazzite_mounts() {
    for m in dev sys proc; do
mountpoint -q "$CHROOT/$m" && umount "$CHROOT/$m" || true
    done
}
trap cleanup_bazzite_mounts RETURN ERR EXIT
mount --bind /proc "$CHROOT/proc"
mount --bind /sys  "$CHROOT/sys"
mount --bind /dev  "$CHROOT/dev"
# Bazzite has no /etc/resolv.conf inside the chroot (symlink target
# doesn't exist yet) — provide a working one so dnf can reach mirrors.
rm -f "$CHROOT/etc/resolv.conf"
cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"
chroot "$CHROOT" /bin/bash -e <<"BAZIN"
    # Disable rpm-ostree services — we're a flat fs now.
    systemctl mask rpm-ostreed.service rpm-ostree-countme.service rpm-ostree-bootstatus.service 2>/dev/null || true
    # Drop the embedded ostree object store + deploy tree. With
    # rpm-ostree masked, the running rootfs is the flat OCI
    # extract — /sysroot/ostree/repo/objects/ is a deduplicated
    # second copy of the same content (~5GB+), and /ostree/
    # deploy/ holds yet another. Wiping them shrinks the disk
    # image roughly in half. Leave the dir skeleton in case
    # anything probes for it.
    rm -rf /sysroot/ostree/repo/objects \
   /sysroot/ostree/repo/refs \
   /sysroot/ostree/deploy
    mkdir -p /sysroot/ostree/repo/objects \
     /sysroot/ostree/repo/refs/heads
    # Bazzite/rpm-ostree convention: /root is a symlink to
    # /var/roothome which doesn't exist in the OCI extract.
    # dracut's hostonly enumeration follows the symlink, hits
    # ENOENT, fails with `dracut-install: ERROR: installing '/root'`.
    # Make /root a real dir so dracut + the kernel postinst's own
    # dracut call both work.
    mkdir -p /var/roothome
    if [ -L /root ]; then
rm -f /root
mkdir -m 0700 /root
    fi
    # Install PS5 kernel via rpm --replacefiles (handles the file-
    # level conflict between our /usr/include/* headers and
    # Bazzite's kernel-headers; see fedora image.yaml comment).
    # Bazzite ships kernel modules as a dir; our rpm wants a symlink.
    rm -rf /lib/modules/*
    rpm -Uvh --replacefiles --replacepkgs --nodeps /var/cache/ps5-rpms/*.rpm
    rm -rf /var/cache/ps5-rpms

    # cyan_skillfish (PS5 Oberon) GPU firmware MUST land in the
    # rootfs uncompressed. The linux-ps5 amdgpu patches write into
    # the request_firmware() buffer to skip Sony's signature header
    # (gfx_v10_0_early_init + amdgpu_sdma_init_microcode). Firmware
    # loaded from a .xz file is decompressed into pages the kernel
    # maps PAGE_KERNEL_RO (fw_decompress_xz_pages -> fw_map_paged_buf
    # -> vmap PAGE_KERNEL_RO), so the write oopses amdgpu at
    # gfx_v10_0_early_init+0x415 and /dev/dri never appears.
    # Distros that ship .zst (arch) or raw .bin (debian) decompress
    # into writable buffers and are unaffected — this fix is for
    # the rpm path only. linux-firmware dedupes blobs as symlinks
    # (mec2 -> mec) and unxz refuses symlinks, so materialize the
    # link targets first while the canonical .xz still exists.
    # Upstream did this same fix in
    # github.com/ps5-linux/ps5-linux-image@ed54e99 — same kernel
    # patches, same firmware, same failure mode.
    cd /usr/lib/firmware/amdgpu
    for f in cyan_skillfish*.xz; do
if [ -L "$f" ]; then
    tgt=$(readlink -f "$f")
    rm "$f"
    xz -dc "$tgt" > "${f%.xz}"
fi
    done
    unxz cyan_skillfish*.xz
    cd /

    # Pre-configure repo.etawen.dev so users can
    # `dnf upgrade linux-ps5` after first boot. Per-package
    # gpgcheck=0 (alien-converted RPMs aren't per-package
    # signed); repodata IS signed by the mia PGP key.
    cat > /etc/yum.repos.d/etawen-ps5.repo <<ETAWEN
[etawen-ps5]
name=Etawen PS5 kernel repo
baseurl=https://repo.etawen.dev/rpm/
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=https://repo.etawen.dev/key.asc
ETAWEN
    # amdgpu options — PS5 Oberon GPU needs dpm disabled or HDMI
    # stays dark. Must land in initramfs (amdgpu loads early).
    mkdir -p /etc/modprobe.d
    cat > /etc/modprobe.d/ps5-amdgpu.conf <<AMDGPU
options amdgpu dpm=0 gpu_recovery=0
AMDGPU
    # Build the initrd, then deploy bzImage+initrd to /boot/efi/
    # for the PS5 kexec loader. (zz-update-boot is the deb-flow
    # helper; bazzite never stages it, so we inline the copies.)
    KVER=$(ls -1t /lib/modules | head -1)
    dracut -f --kver "$KVER" "/boot/initrd.img-$KVER"
    mkdir -p /boot/efi
    cp "/boot/vmlinuz-$KVER" /boot/efi/bzImage
    cp "/boot/initrd.img-$KVER" /boot/efi/initrd.img

    # Suppress first-boot wizards. plasma-setup.service runs on every
    # boot until /etc/plasma-setup-done exists, and its bootutil
    # rewrites SDDM autologin to User=plasma-setup (clobbering our
    # User=ps5) and starts the Plasma OOBE wizard, which prompts the
    # user to create a fresh account. Our build pre-creates ps5; the
    # wizard is unwanted.
    touch /etc/plasma-setup-done
    systemctl mask plasma-setup.service 2>/dev/null || true

    # bazzite-hardware-setup.service runs on every boot until the
    # marker files in /etc/bazzite/ match the image-info.json. Seed
    # them so the script exits at its early-return; also mask it
    # outright since the script calls `rpm-ostree kargs` which fails
    # against our masked rpm-ostreed. The script's other work
    # (zram, IOMMU karg, hw-specific kargs) isn't applicable on PS5
    # anyway — we set our own cmdline in /boot/efi/cmdline.txt.
    mkdir -p /etc/bazzite
    jq -r '."image-name"'     < /usr/share/ublue-os/image-info.json > /etc/bazzite/image_name
    jq -r '."image-branch"'   < /usr/share/ublue-os/image-info.json > /etc/bazzite/image_branch
    jq -r '."fedora-version"' < /usr/share/ublue-os/image-info.json > /etc/bazzite/fedora_version
    grep -oP '^HWS_VER=\K[0-9]+' /usr/libexec/bazzite-hardware-setup > /etc/bazzite/hws_version
    systemctl mask bazzite-hardware-setup.service 2>/dev/null || true

    # User setup. Bazzite exposes video/audio/input/render via
    # systemd-userdbd, so `getent group video` returns a row —
    # and `groupadd -f` short-circuits as "already exists" and
    # does nothing. But useradd reads /etc/group directly (no
    # NSS), sees an empty file, and bails with "group X does not
    # exist". Materialize each group into /etc/group ourselves,
    # preserving the NSS-assigned GID when there is one so
    # existing file ownerships in the rootfs stay correct.
    passwd -l root
    # Ensure /etc/gshadow exists with the right perms; useradd
    # refuses to "prepare new entry" silently if it's missing.
    [ -e /etc/gshadow ] || { touch /etc/gshadow; chmod 0 /etc/gshadow; }
    for g in wheel video audio input render; do
if ! grep -q "^${g}:" /etc/group; then
    gid=$(getent group "$g" 2>/dev/null | cut -d: -f3 || true)
    if [ -z "$gid" ]; then
        # Pick the next free system gid (100-999).
        gid=$(awk -F: 'BEGIN{m=100} $3>=100 && $3<1000 && $3>m {m=$3} END{print m+1}' /etc/group)
    fi
    echo "${g}:x:${gid}:" >> /etc/group
fi
# Always make sure /etc/gshadow has a row.
grep -q "^${g}:" /etc/gshadow || echo "${g}:!::" >> /etc/gshadow
    done
    if ! id ps5 >/dev/null 2>&1; then
useradd -m -s /bin/bash -G wheel,video,audio,input,render ps5
    fi
    echo "ps5:ps5" | chpasswd
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers || true

    # Install pieces Bazzite's slim OCI image is missing.
    #   cloud-utils-growpart + parted: grow-rootfs needs growpart
    #     and partprobe — without them the rootfs stays sized to
    #     the build image (~10GB) on whatever USB it lands on.
    #   plasma-systemmonitor + ksystemstats: standard Plasma
    #     "System Monitor" app. Bazzite's container drops it.
    #   kdiff3 / gwenview / ark / okular / spectacle: rest of
    #     the Plasma utilities most people expect.
    #   chrony: NTP. PS5's RTC is wrong on boot; without an NTP
    #     client the system clock is years off and TLS breaks.
    dnf install -y --setopt=install_weak_deps=False \
cloud-utils-growpart parted \
plasma-systemmonitor ksystemstats \
kdiff3 gwenview ark okular spectacle \
chrony \
|| echo "WARN: dnf install failed; some pkgs may be missing"

    # Services
    systemctl enable grow-rootfs.service NetworkManager sshd 2>/dev/null || true
    # Time sync. Prefer systemd-timesyncd if present (lighter);
    # fall back to chrony (which we just dnf-installed).
    systemctl enable systemd-timesyncd 2>/dev/null \
|| systemctl enable chronyd 2>/dev/null || true
    # Virtual terminals. Bazzite's preset disables getty@tty2-6;
    # explicitly enable them so Ctrl+Alt+F2..F6 give text consoles.
    for n in 2 3 4 5 6; do
systemctl enable getty@tty${n}.service 2>/dev/null || true
    done
    # Default DM (Bazzite ships KDE Plasma + SDDM)
    systemctl enable sddm 2>/dev/null || systemctl enable gdm 2>/dev/null || true
    # resolv.conf -> systemd-resolved stub
    rm -f /etc/resolv.conf
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    # Steam Deck UI's "Switch to Desktop" button calls SteamOS-
    # Manager's SetTemporarySession(s) dbus method, which writes
    # Session=<bare-alias> (literally "desktop"/"gamescope") into
    # /etc/sddm.conf.d/zzt-steamos-temp-login.conf. That conf
    # sorts AFTER zz-steamos-autologin.conf so it wins precedence
    # at autologin time — but SDDM has no `desktop.desktop`
    # session to resolve the alias to, so the button silently
    # no-ops and the user stays on gamescope. (The bash
    # steamos-session-select tool works fine because it resolves
    # aliases itself before writing — only the dbus path is
    # broken.) Fix it with alias symlinks SDDM can follow.
    for cand in plasma-steamos-wayland-oneshot.desktop \
        gnome-wayland-oneshot.desktop plasma.desktop; do
if [ -e "/usr/share/wayland-sessions/$cand" ]; then
    ln -sf "$cand" /usr/share/wayland-sessions/desktop.desktop
    break
fi
    done
    for cand in gamescope-session.desktop gamescope-session-plus.desktop; do
if [ -e "/usr/share/wayland-sessions/$cand" ]; then
    ln -sf "$cand" /usr/share/wayland-sessions/gamescope.desktop
    break
fi
    done
    # Autologin straight into Bazzite's gamescope session (Steam
    # Big-Picture / Deck UI) — Bazzite is gaming-focused, and a
    # field report said it landed on the Plasma desktop instead
    # of gamemode. Pick whichever gamescope session file exists,
    # fall back to plasma if Bazzite stripped them.
    mkdir -p /etc/sddm.conf.d
    SESSION=plasma
    for s in gamescope-session-plus.desktop gamescope-session.desktop steam-wayland.desktop; do
if [ -e "/usr/share/wayland-sessions/$s" ] || [ -e "/usr/share/xsessions/$s" ]; then
    SESSION="${s%.desktop}"
    break
fi
    done
    cat > /etc/sddm.conf.d/autologin.conf <<SDDM
[Autologin]
User=ps5
Session=$SESSION
SDDM

    # Gamescope-session fallback. Field report: bazzite-deck boots
    # to a black screen on PS5 because gamescope can't grab the
    # display (PSP/TA + Salina HDMI bridge weirdness — workaround
    # is `steamos-session-select plasma` from a VT). Automate it:
    # first-boot oneshot waits 60s for a gamescope process; if
    # nothing shows up, flip the session to plasma and bounce
    # SDDM. Only arm this when the chosen session is gamescope-
    # flavoured. After first boot the user owns session choice
    # via the standard steamos-session-select tool + the desktop
    # shortcut we drop below.
    case "$SESSION" in gamescope*|steam-wayland*)
mkdir -p /usr/local/sbin /etc/systemd/system/graphical.target.wants
cat > /usr/local/sbin/ps5-gamescope-recovery <<'POKE'
#!/bin/bash
# Wait up to 60s for gamescope to actually grab a display. If it doesn't,
# the user is staring at a black screen — fall back to plasma and bounce
# the display manager so they get a usable login session.
for _ in $(seq 1 60); do
    sleep 1
    pgrep -x gamescope >/dev/null 2>&1 && exit 0
done
logger -t ps5-gamescope-recovery "gamescope didn't start within 60s, switching to plasma"
runuser -u ps5 -- steamos-session-select plasma 2>/dev/null \
    || sed -i 's/^Session=.*/Session=plasma/' /etc/sddm.conf.d/autologin.conf
systemctl restart sddm
POKE
chmod +x /usr/local/sbin/ps5-gamescope-recovery
cat > /etc/systemd/system/ps5-gamescope-recovery.service <<RECOV
[Unit]
Description=Fall back to plasma if gamescope can't grab a display (first boot)
After=graphical.target
ConditionFirstBoot=yes

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ps5-gamescope-recovery
RemainAfterExit=no

[Install]
WantedBy=graphical.target
RECOV
ln -sf ../ps5-gamescope-recovery.service \
    /etc/systemd/system/graphical.target.wants/ps5-gamescope-recovery.service

# Desktop shortcut so the user can opt back into gamescope
# after a recovery (or after switching to plasma manually).
mkdir -p /home/ps5/Desktop
cat > /home/ps5/Desktop/Switch-to-Gamescope.desktop <<DESK
[Desktop Entry]
Version=1.0
Type=Application
Name=Switch to Gamescope (Big Picture)
Comment=Switch the autologin session back to gamescope / Steam Deck UI
Exec=bash -c 'steamos-session-select gamescope && systemctl restart sddm'
Icon=steam
Terminal=false
Categories=System;
DESK
chmod +x /home/ps5/Desktop/Switch-to-Gamescope.desktop
chown -R ps5:ps5 /home/ps5/Desktop 2>/dev/null || \
    chown -R 1000:1000 /home/ps5/Desktop
;;
    esac

    # DTM TA race workaround. amdgpu's display-topology TA
    # (Trusted Application) loads async via PSP; if DRM probes
    # connectors before that finishes, you get
    #   [drm] Failed to add display topology, DTM TA is not initialized
    # and the screen stays dark until the user manually toggles
    # VT (ctrl+alt+F7 -> ctrl+alt+F1) which forces a re-probe.
    # Mimic that automatically: after amdgpu binds, wait a beat
    # then re-trigger DRM connector detection.
    mkdir -p /usr/local/sbin /etc/udev/rules.d
    cat > /usr/local/sbin/ps5-amdgpu-reprobe <<'POKE'
#!/bin/sh
# Wait for PSP/TA firmware to settle, then re-probe DRM connectors.
# Equivalent of the ctrl+alt+F7 / ctrl+alt+F1 dance.
(
    sleep 3
    for c in /sys/class/drm/card*-*/status; do
[ -w "$c" ] && echo detect > "$c"
    done
) &
POKE
    chmod +x /usr/local/sbin/ps5-amdgpu-reprobe
    cat > /etc/udev/rules.d/70-ps5-amdgpu-reprobe.rules <<'UDEV'
# Re-trigger DRM hotplug after amdgpu binds, so the DTM TA-not-initialized
# race doesn't leave the user with a dark screen until they manually VT-cycle.
SUBSYSTEM=="drm", ACTION=="add", KERNEL=="card[0-9]*", RUN+="/usr/local/sbin/ps5-amdgpu-reprobe"
UDEV
BAZIN
# explicit cleanup (the trap covers the failure path)
cleanup_bazzite_mounts
trap - RETURN ERR EXIT
