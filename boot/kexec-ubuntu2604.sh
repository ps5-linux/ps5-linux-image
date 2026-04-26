#!/bin/sh
# Switch to Ubuntu 26.04 via kexec
set -e
BOOT=/boot/efi
kexec -l "$BOOT/bzImage" --initrd="$BOOT/initrd-ubuntu2604.img" --command-line="$(cat $BOOT/cmdline-ubuntu2604.txt)"
kexec -e
