#!/bin/sh
# Switch to Ubuntu 24.04 via kexec
set -e
BOOT=/boot/efi
kexec -l "$BOOT/bzImage" --initrd="$BOOT/initrd-ubuntu2404.img" --command-line="$(cat $BOOT/cmdline-ubuntu2404.txt)"
kexec -e
