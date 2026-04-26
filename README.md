# PS5 Linux Image Builder

Builds bootable Linux USB images for PlayStation 5 using Docker containers. Supports Ubuntu 24.04, Ubuntu 26.04, Arch, and Alpine, individually or as a multi-distro image with kexec switching.

## Prerequisites

- Docker (with permission to run `--privileged` containers) — install as per your distro's instructions
- ~30GB free disk space

Once Docker is installed, add your user to the docker group and apply it without logging out:

```bash
sudo usermod -aG docker $USER
newgrp docker
```

## Quick Start

```bash
# Build a single Ubuntu 24.04 image
./build_image.sh --distro ubuntu

# Build a single Ubuntu 26.04 image
./build_image.sh --distro ubuntu2604

# Build a multi-distro image (ubuntu + ubuntu2604 + arch + alpine)
./build_image.sh --distro all
```

The script auto-clones the kernel source, applies PS5 patches, compiles, and builds the image. Subsequent runs reuse cached artifacts automatically. Press Ctrl+C at any time to abort cleanly.

## Flash to USB

```bash
sudo dd if=output/ps5-ubuntu.img of=/dev/sdX bs=4M status=progress
```

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `--distro` | `ubuntu`, `ubuntu2604`, `arch`, `alpine`, or `all` | `ubuntu` |
| `--kernel` | Path to kernel source directory | auto-clone `v6.19.10` |
| `--img-size` | Disk image size in MB | `12000` (`32000` for `all`) |
| `--clean` | Remove all cached build artifacts and start fresh | off |

## Caching

The build automatically skips stages that have already completed:

- **Kernel source** — reused if `work/linux/` exists
- **Kernel packages** — reused if `.deb`/`.pkg.tar.zst` files exist in `linux-bin/`
- **Root filesystem** — reused if chroot directories are populated

Use `--clean` to wipe everything and rebuild from scratch. The build will also suggest `--clean` if a stage fails.

## Build Output

```
PS5 Linux Image Builder
=======================
  Distro:       all
                (ubuntu ubuntu2604 arch alpine)
  Image size:   32000MB
  Kernel src:   /path/to/work/linux

Stages:
  1. Kernel            cached
  2. Root filesystem   build
  3. Disk image        build

Logs: /path/to/build.log

  ✓ Kernel packages (cached)
  ✓ Build image builder image
  ⠹ Building arch rootfs
```

All verbose output goes to `build.log`. The terminal shows a spinner with live progress.

## Distributions

| Distro | Desktop | Kernel format | Init |
|--------|---------|---------------|------|
| Ubuntu 24.04 (Noble) | GNOME | `.deb` | systemd |
| Ubuntu 26.04 (Resolute) | GNOME | `.deb` | systemd |
| Arch | Sway | `.pkg.tar.zst` | systemd |
| Alpine (3.21) | GNOME | extracted from `.deb` | OpenRC |

## Multi-distro Image

`--distro all` builds a 32GB image with 5 partitions:

| Partition | Type | Label | Content |
|-----------|------|-------|---------|
| p1 | FAT32 | boot | Shared kernel, per-distro initrds, kexec scripts |
| p2 | ext4 | ubuntu | Ubuntu 24.04 rootfs |
| p3 | ext4 | ubuntu2604 | Ubuntu 26.04 rootfs |
| p4 | ext4 | arch | Arch rootfs |
| p5 | ext4 | alpine | Alpine rootfs |

The boot partition contains kexec scripts to switch between distros at runtime. Ubuntu 24.04 is the default boot target.

## Directory Layout

```
build_image.sh                  # Main build script
docker/
  kernel-builder/               # Kernel compilation container
  kernel-builder-arch/          # Repackages .deb kernel as .pkg.tar.zst
  image-builder/
    Dockerfile                  # Image building container (distrobuilder)
    entrypoint.sh               # Single-distro build logic
    entrypoint-multi.sh         # Multi-distro build logic
distros/
  ubuntu/                       # Ubuntu 24.04 (Noble)
  ubuntu2604/                   # Ubuntu 26.04 (Resolute)
  arch/                         # Arch Linux
  alpine/                       # Alpine 3.21
  shared/                       # Kernel postinst hooks (single + multi)
boot/
  cmdline.txt                   # Kernel cmdline template (__DISTRO__ placeholder)
  vram.txt                      # VRAM allocation
  kexec-{ubuntu,ubuntu2604,arch,alpine}.sh
work/                           # Build artifacts (auto-created)
linux-bin/                      # Compiled kernel packages
output/                         # Final .img files
```
