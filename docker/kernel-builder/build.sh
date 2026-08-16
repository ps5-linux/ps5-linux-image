#!/bin/bash
# Compiles the kernel and stages all artifacts into /out/staging.
# Runs inside Docker; kernel source is bind-mounted at /src.
set -e

# The PS5 Salina Ethernet driver shipped by ps5-linux-patches can requeue an
# empty NAPI poll forever when a sticky interrupt cause is observed. The image
# builder must fail closed if the bounded-NAPI source fix was not applied.
MTS_SOURCE="drivers/net/phy/mts/mts_main.c"
[ -f "$MTS_SOURCE" ] \
    || { echo "ERROR: expected PS5 mts source is missing: $MTS_SOURCE" >&2; exit 1; }
grep -q 'if (!napi_complete_done(napi, rx_done))' "$MTS_SOURCE" \
    || { echo "ERROR: bounded-NAPI mts fix is missing" >&2; exit 1; }
grep -q 'if (rx_done && napi_schedule_prep(&p->napi))' "$MTS_SOURCE" \
    || { echo "ERROR: mts empty-poll guard is missing" >&2; exit 1; }

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

# Build against the kernel source we just built (out-of-tree build needs
# the in-tree build dir, not just headers; same as install-extmod-build).
make -C "$NXP_MW" CONFIG_OBJTOOL= KERNELDIR=/src ARCH=x86 -j"$(nproc)"
[ -f "$NXP_MW/mlan.ko" ] && [ -f "$NXP_MW/moal.ko" ] \
    || { echo "ERROR: mwifiex build did not produce mlan.ko/moal.ko"; exit 1; }

EXTRA_DIR="/out/staging/lib/modules/$KVER/extra/ps5-iw620"
mkdir -p "$EXTRA_DIR"
install -m 0644 "$NXP_MW/mlan.ko" "$EXTRA_DIR/mlan.ko"
install -m 0644 "$NXP_MW/moal.ko" "$EXTRA_DIR/moal.ko"

# Keep the out-of-tree Wi-Fi stack installed for explicit recovery, but do not
# auto-load it. On the PS5 kernel 7.1.7 it can flood malformed scan-TLV
# warnings and is unnecessary when wired Ethernet is available.
mkdir -p /out/staging/etc/modprobe.d /out/staging/etc/modules-load.d
cat > /out/staging/etc/modules-load.d/moal <<'MODULES'
# Disabled by default. Use /usr/local/sbin/ps5-wifi-enable explicitly after
# confirming the NXP firmware and accepting the experimental driver status.
MODULES
cat > /out/staging/etc/modprobe.d/moal.conf <<'MPCONF'
# PS5 IW620 mwifiex (NXP moal/mlan, built out-of-tree by kernel-builder).
softdep moal pre: cfg80211 mlan
options moal fw_name=nxp/pcieuartiw620_combo_v1.bin pcie_int_mode=1 drv_mode=1 cfg80211_wext=4 sta_name=mlan ext_scan=1 auto_fw_reload=0 wifi_reset_config=0 sched_scan=0 ps_mode=2 auto_ds=2 amsdu_disable=1
MPCONF
cat > /out/staging/etc/modprobe.d/ps5-disable-broken-wifi.conf <<'BLACKLIST'
# Wired Ethernet is the supported default. Remove this file or run
# ps5-wifi-enable before loading moal/mlan manually.
blacklist moal
blacklist mlan
BLACKLIST

cat > /out/staging/usr/local/sbin/ps5-wifi-enable <<'HELPER'
#!/bin/sh
set -eu
BLACKLIST=/etc/modprobe.d/ps5-disable-broken-wifi.conf
if [ -f "$BLACKLIST" ]; then
    mv "$BLACKLIST" "$BLACKLIST.disabled"
fi
modprobe cfg80211 || true
modprobe moal
rfkill unblock all 2>/dev/null || true
nmcli radio wifi on 2>/dev/null || true
HELPER
chmod +x /out/staging/usr/local/sbin/ps5-wifi-enable

cat > /out/staging/usr/local/sbin/ps5-wifi-disable <<'HELPER'
#!/bin/sh
set -eu
BLACKLIST=/etc/modprobe.d/ps5-disable-broken-wifi.conf
nmcli radio wifi off 2>/dev/null || true
modprobe -r moal mlan 2>/dev/null || true
if [ ! -e "$BLACKLIST" ]; then
    cat > "$BLACKLIST" <<'BLACKLIST'
blacklist moal
blacklist mlan
BLACKLIST
fi
HELPER
chmod +x /out/staging/usr/local/sbin/ps5-wifi-disable

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
if [ ! -e "$DST" ]; then
    echo "PS5 IW620 firmware not found; Wi-Fi remains disabled"
fi
HELPER
chmod +x /out/staging/usr/local/sbin/ps5-stage-firmware

cat > /out/staging/etc/systemd/system/ps5-stage-firmware.service <<'UNIT'
[Unit]
Description=Stage PS5 NXP IW620 wifi firmware from EFI partition
RequiresMountsFor=/boot/efi
After=local-fs.target
Before=NetworkManager.service
ConditionPathExists=/boot/efi/lib/nxp/pcieuartiw620_combo_v1.bin

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ps5-stage-firmware
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
ln -sf ../ps5-stage-firmware.service \
    /out/staging/etc/systemd/system/multi-user.target.wants/ps5-stage-firmware.service

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

echo "=== Build artifacts staged in /out/staging ==="
