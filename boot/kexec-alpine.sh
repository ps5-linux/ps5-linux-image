#!/bin/sh
# Switch to Alpine Linux via kexec
set -e
BOOT=/boot/efi
kexec -l "$BOOT/bzImage" --initrd="$BOOT/initrd-alpine.img" --command-line="$(cat $BOOT/cmdline-alpine.txt)"
kexec -e
