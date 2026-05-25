# PS5 Linux Image Builder

Builds bootable Linux USB images for PlayStation 5 using Docker containers. Supports Ubuntu 26.04, Arch, CachyOS (Gamescope + Steam), and full Kali Linux, individually or as a multi-distro image with kexec switching.

## Prerequisites

- Docker (with permission to run `--privileged` containers) — install as per your distro's instructions
- ~30GB free disk space for Ubuntu, Arch, or CachyOS; a full Kali build needs
  substantial working space because it creates a 96GB image and a full rootfs
  tree (`~150GB` free recommended for a clean Kali build)

Once Docker is installed, add your user to the docker group and apply it without logging out:

```bash
sudo usermod -aG docker $USER
newgrp docker
```

## Quick Start

```bash
# Build a single Ubuntu 26.04 image
./build_image.sh --distro ubuntu2604

OR

# Build CachyOS (Arch-based, Gamescope + Steam Big Picture)
./build_image.sh --distro cachyos

OR

# Build Kali Linux (XFCE + kali-linux-everything)
./build_image.sh --distro kali

OR

# Build a multi-distro image (ubuntu2604 + arch + cachyos)
./build_image.sh --distro all
```

The script auto-clones the kernel source, applies PS5 patches, compiles, and builds the image. Subsequent runs reuse cached artifacts automatically. Press Ctrl+C at any time to abort cleanly.

## Flash to USB

```bash
sudo dd if=output/ps5-ubuntu2604.img of=/dev/sdX bs=4M status=progress
```

## Kali First Boot Time Sync

The Kali image uses UTC by default and enables `ntpsec`. PS5 hardware may boot
Linux without a correct real-time clock, so the displayed time can be wrong
until a network connection is available. The Kali recipe configures IPv4 NTP
sources that were validated through Android USB tethering, because that
connection may not provide usable IPv6 routing.

The Xfce clock's **Time and Date** window is the legacy `time-admin` utility.
On Kali it can report that NTP support is not installed even though `ntpsec`
is installed and active. Verify or repair synchronization from a terminal:

```bash
systemctl --no-pager status ntpsec
ntpq -pn
timedatectl status
```

If the PS5 clock is still wrong after the internet connection is active, force
one initial correction and restart continuous synchronization:

```bash
sudo systemctl stop ntpsec
sudo ntpd -gq -c /etc/ntpsec/ntp.conf
sudo systemctl start ntpsec
date
```

To use a local timezone after boot, for example Kentucky:

```bash
sudo timedatectl set-timezone America/Kentucky/Louisville
timedatectl status
```

The Kali desktop autologin is enabled for local first boot. SSH is installed
but disabled by default because the initial local account is `kali` with
password `kali`. Before enabling remote access, change that password:

```bash
passwd
sudo systemctl enable --now ssh
```

The image holds its installed kernel packages and protects the boot-copy hook
from deploying a generic Kali kernel. Do not replace or unhold the PS5 kernel
unless you are intentionally testing a new PS5-patched kernel build.

Ghidra is configured to use JDK 21, its documented supported runtime. Full
Kali installations may also contain newer Java versions for other software.

`kali-linux-everything` installs NFS client components, but the PS5-patched
kernel has NFS disabled. A failed `run-rpc_pipefs.mount` unit can therefore be
reported at boot; it only indicates that NFS mounts are unavailable. The Kali
desktop and security tools are unaffected.

The full Kali toolset also enables `chkrootkit.timer`; its daily integrity scan
can use noticeable CPU time while it runs.

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `--distro` | `ubuntu2604`, `arch`, `cachyos`, `kali`, or `all` | `ubuntu2604` |
| `--kernel` | Path to kernel source directory | auto-clone version selected by PS5 patch set |
| `--img-size` | Disk image size in MB | `12000` (`32000` for `all`, `98304` for `kali`) |
| `--clean` | Remove all cached build artifacts and start fresh | off |
| `--kernel-only` | Build and package the kernel only, then exit | off |
| `--patches-ref` | Branch, tag, or commit SHA for patches | `v1.2` |

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
                (ubuntu2604 arch cachyos)
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
| Ubuntu 26.04 (Resolute) | GNOME | `.deb` | systemd |
| Arch | Sway | `.pkg.tar.zst` | systemd |
| CachyOS | Gamescope + Steam Big Picture (Arch + `[cachyos]` repo, no v3 migration in image build) | `.pkg.tar.zst` | systemd |
| Kali Linux Rolling | XFCE + `kali-linux-everything` | `.deb` | systemd |

## Multi-distro Image

`--distro all` builds a 32GB image with 4 partitions (one EFI boot partition plus three root filesystems):

| Partition | Type | Label | Content |
|-----------|------|-------|---------|
| p1 | FAT32 | boot | Shared kernel, per-distro initrds, kexec scripts |
| p2 | ext4 | ubuntu2604 | Ubuntu 26.04 rootfs |
| p3 | ext4 | arch | Arch rootfs |
| p4 | ext4 | cachyos | CachyOS rootfs |

The boot partition contains kexec scripts to switch between distros at runtime. Ubuntu 26.04 is the default boot target.

## Building the Kernel Standalone

Use `--kernel-only` to compile the PS5 kernel and produce installable packages without building a full disk image.

```bash
./build_image.sh --kernel-only                                # .deb (default)
./build_image.sh --kernel-only --distro all                   # .deb + .pkg.tar.zst
./build_image.sh --kernel-only --patches-ref main             # fetch from specific branch/tag
./build_image.sh --kernel-only --clean                        # wipe and rebuild from scratch
```

Output packages are written to `linux-bin/`. Install on a running PS5 Linux system:

```bash
sudo dpkg -i linux-bin/linux-ps5_*.deb
```

## Directory Layout

```
build_image.sh                  # Image builder (also supports --kernel-only)
docker/
  kernel-builder/               # Kernel compilation container
  kernel-builder-arch/         # Repackages .deb kernel as .pkg.tar.zst
  image-builder/
    Dockerfile                  # Image building container (distrobuilder)
    entrypoint.sh               # Single-distro build logic
    entrypoint-multi.sh         # Multi-distro build logic
distros/
  ubuntu2604/                   # Ubuntu 26.04 (Resolute)
  arch/                         # Arch Linux
  cachyos/                      # CachyOS repos + Gamescope/Steam
  kali/                         # Kali Linux Rolling
  shared/                       # Kernel postinst hooks (single + multi)
boot/
  cmdline.txt                   # Kernel cmdline template (__DISTRO__ placeholder)
  vram.txt                      # VRAM allocation
  kexec-{ubuntu2604,arch,cachyos}.sh
work/                           # Build artifacts (auto-created)
linux-bin/                      # Compiled kernel packages
output/                         # Final .img files
```
