#!/bin/sh
# Switch to CachyOS (Gamescope + Steam) via kexec
set -e
BOOT=/boot/efi
kexec -l "$BOOT/bzImage" --initrd="$BOOT/initrd-cachyos.img" --command-line="$(cat $BOOT/cmdline-cachyos.txt)"
kexec -e
