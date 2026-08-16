#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

fail() {
    echo "validate-ps5-image: $*" >&2
    exit 1
}

require_file() {
    [ -f "$1" ] || fail "missing file: $1"
}

require_text() {
    local needle=$1
    local file=$2
    grep -Fq -- "$needle" "$file" || fail "missing '$needle' in $file"
}

for file in \
    build_image.sh \
    boot/cmdline.txt \
    distros/cachyos/image.yaml \
    distros/cachyos/files/grow-rootfs \
    distros/cachyos/files/grow-rootfs.service \
    distros/cachyos/files/first-boot-setup \
    distros/cachyos/files/gamescope-session-ps5 \
    distros/cachyos/files/ps5-firewall.nft \
    distros/cachyos/files/ps5-ssh-setup \
    distros/cachyos/files/ps5-steam-session \
    docker/kernel-builder/build.sh \
    kernel-patches/0001-mts-bounded-napi.patch; do
    require_file "$file"
done

if grep -R -n --exclude-dir=.git --exclude='*.md' 'mitigations=off' \
    boot/cmdline.txt distros/*/cmdline.txt 2>/dev/null; then
    fail "insecure mitigations=off remains in a boot command line"
fi

require_text 'quiet loglevel=3 systemd.show_status=auto' boot/cmdline.txt
require_text 'if (!napi_complete_done(napi, rx_done))' kernel-patches/0001-mts-bounded-napi.patch
require_text 'if (rx_done && napi_schedule_prep(&p->napi))' kernel-patches/0001-mts-bounded-napi.patch
require_text 'Apply local PS5 kernel fixes' build_image.sh
require_text 'LOCAL_KERNEL_PATCH_STAMP' build_image.sh
require_text 'patches-ref=%s' build_image.sh
require_text 'patches-config=%s' build_image.sh
require_text 'zram-size = 4096' distros/cachyos/files/zram-generator.conf
require_text 'PasswordAuthentication no' distros/cachyos/files/10-ps5-hardening.conf
require_text 'nftables.service' distros/cachyos/image.yaml
require_text 'LANG=en_US.UTF-8' distros/cachyos/image.yaml
require_text 'multi-user.target.wants/grow-rootfs.service' distros/cachyos/image.yaml
require_text 'sgdisk --backup=' distros/cachyos/files/grow-rootfs
require_text 'sfdisk --dump' distros/cachyos/files/grow-rootfs
require_text 'unsupported root disk' distros/cachyos/files/grow-rootfs
require_text 'multi-user.target.wants/grow-rootfs.service' distros/arch/image.yaml
require_text 'ConditionPathExists=!/etc/ps5-first-boot-done' distros/cachyos/files/first-boot.service
require_text 'passwd -l steam' distros/cachyos/image.yaml
require_text 'steam ALL=(root) NOPASSWD:' distros/cachyos/image.yaml
require_text 'blacklist moal' docker/kernel-builder/build.sh
require_text 'if (rx_done && napi_schedule_prep(&p->napi))' docker/kernel-builder/build.sh
if grep -Fq '%config(noreplace) /etc/modules-load.d/moal' docker/kernel-builder-rpm/linux-ps5.spec; then
    fail "RPM would preserve an old auto-loading moal modules-load file"
fi

while IFS= read -r -d '' file; do
    bash -n "$file"
done < <(find . -type f \( -name '*.sh' -o -name '*.bash' \) \
    -not -path './work/*' -not -path './output/*' -not -path './linux-bin/*' -print0)

if command -v ruby >/dev/null 2>&1; then
    ruby -e 'require "yaml"; ARGV.each { |f| YAML.load_file(f) }' \
        distros/cachyos/image.yaml
fi

git diff --check
echo "validate-ps5-image: ok"
