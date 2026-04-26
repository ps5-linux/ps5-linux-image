#!/bin/sh
# Switch to Arch Linux via kexec
set -e
BOOT=/boot/efi
kexec -l "$BOOT/bzImage" --initrd="$BOOT/initrd-arch.img" --command-line="$(cat $BOOT/cmdline-arch.txt)"
kexec -e
