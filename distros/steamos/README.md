# steamos

SteamOS 3 image variant for PS5, built by extracting the rootfs from
Valve's official Steam Deck recovery image and swapping in our
`linux-ps5` kernel.

## Source

- Upstream: <https://steamdeck-images.steamos.cloud/recovery/steamdeck-repair-latest.img.bz2>
  (Steam Deck recovery image; SteamOS Holo Arch-based.)
- ~3.4 GB compressed bz2, ~10 GB decompressed.
- Valve CDN — no per-IP throttle observed; first-time cache pull on a
  cold runner is ~3-5 min, subsequent runs are instant via
  `/data/cache/ps5/downloads/`.

## What the build does

1. Resolve `steamdeck-repair-latest.img.bz2` → its dated filename so
   the cache key is stable.
2. Decompress → losetup -P.
3. Mount the first **erofs** partition (rootfs-A; A and B are
   identical) read-only, `cp -a` to `$CHROOT`.
4. Mount the first **ext4 < 2 GB** partition that contains `/lib`
   (var-A), `cp -a` to `$CHROOT/var` — SteamOS splits `/var` off the
   rootfs and first-boot fails without it.
5. Extract our `linux-ps5-*.pkg.tar.zst` and merge `usr/`, `boot/`,
   `etc/` into `$CHROOT`.
6. Delete SteamOS's `linux-neptune` kernel + modules so grub boots
   ours.
7. `depmod -a $KVER`.

The standard image-builder flow then packs `$CHROOT` into an ext4
image with our EFI partition.

## Caveats

- The Steam UI session expects the Deck's `jupiter` hardware quirks
  (gamepad, ALS, fan curve daemons) — most of those won't apply on
  PS5. Falling back to plasma desktop on the first session is normal.
- SteamOS is read-only by design (steamos-readonly enable). The image
  we build here is regular ext4; if you want the read-only A/B atomic
  experience, that needs a separate variant.
