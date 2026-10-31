#!/bin/bash
# Compiles the kernel and stages all artifacts into /out/staging.
# Runs inside Docker; kernel source is bind-mounted at /src.
set -e

# Clean host-built tool artifacts that may reference wrong include paths
make -C tools/objtool clean 2>/dev/null || true

make olddefconfig
make -j"$(nproc)" bzImage modules

# Stage all artifacts so downstream packagers don't need to run make
echo "=== Staging build artifacts ==="
rm -rf /out/staging
mkdir -p /out/staging/boot

cp arch/x86/boot/bzImage /out/staging/boot/
cp System.map             /out/staging/
cp .config                /out/staging/

make modules_install INSTALL_MOD_PATH=/out/staging INSTALL_MOD_STRIP=1

# Remove dangling symlinks back into the source tree
KVER=$(make -s kernelrelease)
rm -f "/out/staging/lib/modules/$KVER/build" \
      "/out/staging/lib/modules/$KVER/source"

# Stage kernel headers for out-of-tree module builds
echo "=== Staging kernel headers ==="
HDR="/out/staging/headers"
make headers_install INSTALL_HDR_PATH="$HDR/usr"

# Use the kernel's own install-extmod-build script (same as deb-pkg uses)
export srctree=/src SRCARCH=x86
CC="${CROSS_COMPILE}gcc" HOSTCC=gcc MAKE=make /src/scripts/package/install-extmod-build "$HDR/lib/modules/$KVER/build"

# ---- NXP IW620 mwifiex driver (the PS5's onboard wifi) ----
# Build the out-of-tree moal+mlan modules against the kernel we just built
# and stage them into /out/staging so they get bundled in linux-ps5.{deb,rpm,
# pkg.tar.zst}. Without this, users get no wifi until they manually run
# ps5-linux-mwifiex/install.sh on the target (which needs gcc + headers).
echo "=== Building NXP IW620 mwifiex driver ==="
MWIFIEX_REPO="${MWIFIEX_REPO:-https://github.com/ps5-linux/ps5-linux-mwifiex.git}"
MWIFIEX_REF="${MWIFIEX_REF:-main}"
MWIFIEX_NXP_REPO=https://github.com/nxp-imx/mwifiex.git
MWIFIEX_NXP_REF=lf-6.18.2_1.0.0

PS5_MW=/tmp/ps5-linux-mwifiex
NXP_MW=/tmp/nxp-mwifiex
rm -rf "$PS5_MW" "$NXP_MW"
git clone "$MWIFIEX_REPO" "$PS5_MW"
git -C "$PS5_MW" checkout "$MWIFIEX_REF" 2>/dev/null || true
git clone --depth 1 --branch "$MWIFIEX_NXP_REF" "$MWIFIEX_NXP_REPO" "$NXP_MW"
git -C "$NXP_MW" apply "$PS5_MW/ps5-iw620.patch"
git -C "$NXP_MW" apply "$PS5_MW/ps5-iw620-cmd-timeout-recover.patch"
git -C "$NXP_MW" apply "$PS5_MW/ps5-iw620-kernel71-compat.patch"
git -C "$NXP_MW" apply "$PS5_MW/ps5-iw620-kernel72-compat.patch"

# Build against the kernel source we just built (out-of-tree build needs
# the in-tree build dir, not just headers; same as install-extmod-build).
make -C "$NXP_MW" CONFIG_OBJTOOL= KERNELDIR=/src ARCH=x86 -j"$(nproc)"
[ -f "$NXP_MW/mlan.ko" ] && [ -f "$NXP_MW/moal.ko" ] \
    || { echo "ERROR: mwifiex build did not produce mlan.ko/moal.ko"; exit 1; }

EXTRA_DIR="/out/staging/lib/modules/$KVER/extra/ps5-iw620"
mkdir -p "$EXTRA_DIR"
install -m 0644 "$NXP_MW/mlan.ko" "$EXTRA_DIR/mlan.ko"
install -m 0644 "$NXP_MW/moal.ko" "$EXTRA_DIR/moal.ko"

# Modprobe + modules-load.d so the driver auto-loads at boot.
mkdir -p /out/staging/etc/modprobe.d /out/staging/etc/modules-load.d
echo moal > /out/staging/etc/modules-load.d/moal
cat > /out/staging/etc/modprobe.d/moal.conf <<'MPCONF'
# PS5 IW620 mwifiex (NXP moal/mlan, built out-of-tree by kernel-builder).
softdep moal pre: cfg80211 mlan
options moal fw_name=nxp/pcieuartiw620_combo_v1.bin pcie_int_mode=1 drv_mode=1 cfg80211_wext=4 sta_name=mlan ext_scan=1 auto_fw_reload=0 wifi_reset_config=0 sched_scan=0 ps_mode=2 auto_ds=2 amsdu_disable=1
MPCONF

# Rebuild module index so modprobe moal works without depmod -a post-install.
depmod -b /out/staging "$KVER"

# ---- PS5 runtime helpers packaged with the kernel ----
mkdir -p /out/staging/usr/local/sbin
mkdir -p /out/staging/etc/systemd/system/sysinit.target.wants
mkdir -p /out/staging/etc/systemd/system/multi-user.target.wants

cat > /out/staging/usr/local/sbin/ps5-stage-firmware <<'HELPER'
#!/bin/sh
set -eu
FW=nxp/pcieuartiw620_combo_v1.bin
if [ -f /run/ostree-booted ]; then
    DST_DIR=/etc/firmware
    echo "$DST_DIR" > /sys/module/firmware_class/parameters/path 2>/dev/null || true
else
    DST_DIR=/lib/firmware
fi
DST=$DST_DIR/$FW
[ -e "$DST" ] || for d in /efi /boot/efi /boot; do
    if [ -f "$d/lib/$FW" ]; then
        install -Dm644 "$d/lib/$FW" "$DST"
        break
    fi
done
modprobe -r moal mlan 2>/dev/null || true
modprobe moal 2>/dev/null || true
HELPER
chmod +x /out/staging/usr/local/sbin/ps5-stage-firmware

cat > /out/staging/etc/systemd/system/ps5-stage-firmware.service <<'UNIT'
[Unit]
Description=Stage PS5 NXP IW620 wifi firmware from EFI partition
After=local-fs.target
Before=systemd-modules-load.service network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ps5-stage-firmware
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
UNIT
ln -sf ../ps5-stage-firmware.service \
    /out/staging/etc/systemd/system/sysinit.target.wants/ps5-stage-firmware.service

cat > /out/staging/usr/local/sbin/ps5-bt-quiet <<'HELPER'
#!/bin/sh
for i in $(seq 1 15); do
    [ -n "$(ls /sys/class/bluetooth/hci* 2>/dev/null)" ] && break
    sleep 1
done
for h in /sys/class/bluetooth/hci*; do
    [ -e "$h/address" ] || continue
    idx=$(basename "$h" | sed 's/hci//')
    addr=$(cat "$h/address")
    if [ "$addr" = "00:00:00:00:00:00" ]; then
        hciconfig hci$idx down 2>/dev/null || btmgmt -i $idx power off 2>/dev/null || true
    else
        bluetoothctl -- select "$addr" >/dev/null 2>&1 || true
        bluetoothctl -- power on       >/dev/null 2>&1 || true
    fi
done
HELPER
chmod +x /out/staging/usr/local/sbin/ps5-bt-quiet

cat > /out/staging/etc/systemd/system/ps5-bt-quiet.service <<'UNIT'
[Unit]
Description=PS5: silence broken hciN + power the working one
After=bluetooth.service
Wants=bluetooth.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ps5-bt-quiet
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
ln -sf ../ps5-bt-quiet.service \
    /out/staging/etc/systemd/system/multi-user.target.wants/ps5-bt-quiet.service

cat > /out/staging/usr/local/sbin/ps5-stage-gpu-firmware <<'HELPER'
#!/bin/sh
# Stages the PS5 Pro (Viola) GPU firmware that ps5-linux-loader dumps to the
# boot partition. If all of it is there, it is copied to /usr/lib/firmware/amdgpu.
# If amdgpu loads from the initramfs, that is rebuilt and deployed with
# zz-update-boot, or copied to the boot partition on bazzite. amdgpu uses the
# firmware from the next boot on.
set -eu

BOOT=/boot/efi
SRC=$BOOT/lib/firmware/amdgpu
DST=/usr/lib/firmware/amdgpu
STAMP=/var/lib/ps5-stage-gpu-firmware/deployed
HOOK=/etc/kernel/postinst.d/zz-update-boot
NAMES="viola_ce.bin viola_me.bin viola_mec.bin viola_mec2.bin viola_pfp.bin viola_rlc.bin viola_sdma.bin viola_sdma1.bin"
KVER=$(uname -r)
INITRD=/boot/initrd.img-$KVER

log() { echo "ps5-stage-gpu-firmware: $*"; }

# cmp is not on every image.
same() {
    [ -f "$2" ] && [ "$(sha256sum < "$1")" = "$(sha256sum < "$2")" ]
}

# PS5 Pro only: its GPU is 1002:13da.
pro=
for d in /sys/bus/pci/devices/*; do
    case "$(cat "$d/vendor" "$d/device" 2>/dev/null | tr '\n' :)" in
        0x1002:0x13da:) pro=1 ;;
    esac
done
if [ -z "$pro" ]; then
    log "not a PS5 Pro, not staging"
    exit 0
fi

# How the image deploys the initrd: zz-update-boot, or on bazzite a plain copy
# to $BOOT/initrd.img like its build and the kernel rpm do. batocera and
# steamos build their initrd differently.
if [ -x "$HOOK" ]; then
    deploy=hook
elif [ -f /usr/share/ublue-os/image-info.json ] && [ -f "$BOOT/initrd.img" ]; then
    deploy=copy
else
    log "no $HOOK, not staging"
    exit 0
fi

missing=
for n in $NAMES; do
    [ -s "$SRC/$n" ] || missing="$missing $n"
done
if [ -n "$missing" ]; then
    log "not in $SRC:$missing, not staging"
    exit 0
fi

if ! modinfo -k "$KVER" -F firmware amdgpu 2>/dev/null | grep -qx 'amdgpu/viola_ce.bin'; then
    log "amdgpu of $KVER does not load Viola firmware, not staging"
    exit 0
fi

# What the last successful run deployed: kernel and firmware checksums.
state="$KVER $(cd "$SRC" && sha256sum $NAMES | sha256sum | cut -d' ' -f1)"

copied=1
for n in $NAMES; do
    same "$SRC/$n" "$DST/$n" || copied=
done
if [ -n "$copied" ] && [ "$(cat "$STAMP" 2>/dev/null || true)" = "$state" ]; then
    log "Viola firmware is already staged for $KVER"
    exit 0
fi

# All or nothing: copy to temporary names first, then rename.
if [ -z "$copied" ]; then
    mkdir -p "$DST"
    trap 'for n in $NAMES; do rm -f "$DST/.$n.new"; done' EXIT
    for n in $NAMES; do
        install -m644 "$SRC/$n" "$DST/.$n.new"
    done
    for n in $NAMES; do
        mv -f "$DST/.$n.new" "$DST/$n"
    done
    trap - EXIT
    log "copied Viola firmware from $SRC to $DST"
fi

if command -v update-initramfs >/dev/null 2>&1; then
    list=lsinitramfs
elif command -v mkinitcpio >/dev/null 2>&1; then
    list=lsinitcpio
elif command -v dracut >/dev/null 2>&1; then
    list=lsinitrd
else
    log "no update-initramfs, mkinitcpio or dracut"
    exit 1
fi

viola_in_initrd() {
    "$list" "$INITRD" 2>/dev/null | grep -o 'firmware/amdgpu/viola_[a-z0-9]*\.bin' | sort -u | wc -l
}

# amdgpu loaded from the root filesystem finds the firmware in $DST.
if [ -f "$INITRD" ] && ! "$list" "$INITRD" 2>/dev/null | grep -q '/amdgpu\.ko'; then
    log "amdgpu is not in $INITRD, nothing to rebuild"
    mkdir -p "${STAMP%/*}"
    echo "$state" > "$STAMP"
    exit 0
fi

# Rebuild if the firmware was just copied or the initramfs lacks some of it.
if [ -z "$copied" ] || [ ! -f "$INITRD" ] || [ "$(viola_in_initrd)" -ne 8 ]; then
    log "rebuilding $INITRD"
    case $list in
        lsinitramfs)
            if [ -e "$INITRD" ]; then
                update-initramfs -u -k "$KVER"
            else
                update-initramfs -c -k "$KVER"
            fi
            ;;
        # mkinitcpio may warn about missing optional modules; the check below decides
        lsinitcpio) mkinitcpio -k "$KVER" -g "$INITRD" || true ;;
        lsinitrd) dracut --force --no-hostonly "$INITRD" "$KVER" ;;
    esac

    # Only deploy an initramfs that really has all of the firmware.
    have=$(viola_in_initrd)
    if [ "$have" -ne 8 ]; then
        log "$INITRD has $have of 8 Viola firmware files, not deploying it"
        exit 1
    fi
fi

# zz-update-boot names the initrd per distro on multi-distro images.
deployed=
for f in "$BOOT"/initrd.img "$BOOT"/initrd-*.img; do
    same "$INITRD" "$f" && deployed=1
done
if [ -z "$deployed" ]; then
    if [ "$deploy" = hook ]; then
        "$HOOK" "$KVER"
    else
        mv -f "$BOOT/initrd.img" "$BOOT/initrd.img.old"
        if ! cp "$INITRD" "$BOOT/initrd.img"; then
            rm -f "$BOOT/initrd.img"
            mv -f "$BOOT/initrd.img.old" "$BOOT/initrd.img"
            log "could not copy $INITRD to $BOOT, kept the old initrd"
            exit 1
        fi
    fi
    sync
    log "deployed $INITRD to $BOOT, amdgpu uses the Viola firmware from the next boot"
else
    log "$INITRD with Viola firmware is already deployed to $BOOT"
fi

mkdir -p "${STAMP%/*}"
echo "$state" > "$STAMP"
HELPER
chmod +x /out/staging/usr/local/sbin/ps5-stage-gpu-firmware

cat > /out/staging/etc/systemd/system/ps5-stage-gpu-firmware.service <<'UNIT'
[Unit]
Description=Stage PS5 Pro (Viola) GPU firmware from EFI partition
RequiresMountsFor=/boot/efi /usr/lib/firmware /var/lib
After=local-fs.target
ConditionPathExists=/boot/efi/lib/firmware/amdgpu

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ps5-stage-gpu-firmware

[Install]
WantedBy=multi-user.target
UNIT
ln -sf ../ps5-stage-gpu-firmware.service \
    /out/staging/etc/systemd/system/multi-user.target.wants/ps5-stage-gpu-firmware.service

echo "=== Build artifacts staged in /out/staging ==="
