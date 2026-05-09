#!/bin/bash
# Pacman .INSTALL script for linux-ps5.
# KVER is replaced at package build time.

post_install() {
    KVER="__KVER__"
    echo ">> linux-ps5 post_install: kernel $KVER"

    # Rebuild initramfs
    if command -v mkinitcpio >/dev/null 2>&1; then
        echo ">> Rebuilding initramfs with mkinitcpio for $KVER"
        mkinitcpio -k "$KVER" -g "/boot/initrd.img-$KVER"
    fi

    # Copy kernel + initrd to EFI partition
    if [ -d /boot/efi ]; then
        OLD_BZ=$(ls -l /boot/efi/bzImage 2>/dev/null | awk '{print $5}') || true
        OLD_INITRD=$(ls -l /boot/efi/initrd.img 2>/dev/null | awk '{print $5}') || true
        echo ">> Copying /boot/vmlinuz-$KVER -> /boot/efi/bzImage"
        cp "/boot/vmlinuz-$KVER" /boot/efi/bzImage
        NEW_BZ=$(ls -l /boot/efi/bzImage | awk '{print $5}')
        echo ">>   bzImage: ${OLD_BZ:-<new>} -> $NEW_BZ bytes"
        echo ">> Copying /boot/initrd.img-$KVER -> /boot/efi/initrd.img"
        cp "/boot/initrd.img-$KVER" /boot/efi/initrd.img
        NEW_INITRD=$(ls -l /boot/efi/initrd.img | awk '{print $5}')
        echo ">>   initrd.img: ${OLD_INITRD:-<new>} -> $NEW_INITRD bytes"
        echo ">> Kernel $KVER deployed to /boot/efi"
    else
        echo ">> /boot/efi not found, skipping EFI deploy"
    fi
}

post_upgrade() {
    post_install
}
