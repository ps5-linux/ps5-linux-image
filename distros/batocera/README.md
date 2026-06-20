# batocera

Adds support for [Batocera](https://batocera.org/) (Buildroot-based
retro-emulation distro) on PS5 hardware.

Batocera ships as an `.img.gz` with FAT32 boot + ext4 SHARE partitions; the
OS itself lives in a squashfs at `/boot/batocera`.
`distros/batocera/build-rootfs.sh` downloads + unsquashes that image and
swaps in the linux-ps5 kernel:

1. Download `https://mirrors.o2switch.fr/batocera/x86_64/stable/last/`
2. Loop-mount the FAT32, find the embedded squashfs
3. `unsquashfs` to `$CHROOT`
4. Extract the linux-ps5 `.deb`'s `vmlinuz` → `/boot/bzImage`
5. Patch `libretroControllers.py` (PS5 controller-mapping fix)
6. Set up first-boot SHARE partition creator (`ps5-share-init`)
7. Write fstab with `/boot vfat` (NOT `/boot/efi` — batocera-part's
   SHARE auto-detection greps `/proc/mounts` for `/boot`)

## Build locally

```bash
./build_image.sh --distro batocera
```

Image size: 16 GB default (Batocera unsquashes to ~6 GB; headroom for
/userdata).  Override the batocera release with `BATOCERA_VER` /
`BATOCERA_BUILD` envs (defaults track the upstream "last" channel).
