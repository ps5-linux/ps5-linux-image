#!/bin/sh
# Switch to Ubuntu via kexec
set -e
BOOT=/boot/efi
kexec -l "$BOOT/bzImage" --initrd="$BOOT/initrd-ubuntu.img" --command-line="$(cat $BOOT/cmdline-ubuntu.txt)"
kexec -e
