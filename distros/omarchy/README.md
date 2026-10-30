# omarchy

[Omarchy](https://omarchy.org) — DHH's opinionated Arch + Hyprland desktop — on
PS5 hardware with our `linux-ps5` kernel.

## How it is built

Omarchy's installer is an ISO wizard (`archinstall` plus the target-side
`omarchy apply system` step), but the desktop itself ships as ordinary Arch
packages in Omarchy's own repo (`omarchy`, `omarchy-settings`,
`omarchy-keyring`, themes, nvim config, titlebars). Omarchy's own docs describe
prebuilt images as a supported shape: the builder installs the packages and
their setup, and hardware leaves run on the machine's first boot
(`docs/file-layout.md`, `agents/skills/install-scripts.md`).

So this distro is not a hand-assembled copy of the package lists:

1. `distros/omarchy/build-rootfs.sh` fetches `omarchy.db` plus the six
   runtime/support packages from `https://pkgs.omarchy.org/stable/x86_64` into
   the build cache (`stage-pkgs.sh`), then runs distrobuilder on
   `distros/omarchy/image.yaml`.
2. `image.yaml` installs a small Arch base — GPU, session plumbing, network,
   plus `gum`/`perl`/`sddm` for `omarchy-settings` — drops in `linux-ps5`, and
   rebuilds the initramfs without `autodetect`.
3. Its post-files action installs the staged Omarchy packages
   (`pacman -U --nodeps`, the chroot has no DNS), uses Omarchy's pacman
   configuration (its repo first, then Arch off Omarchy's stable mirror, as
   `omarchy apply pacman` would), and runs
   `distros/omarchy/post-install.sh`: Omarchy's `config/` and `login/` setup
   leaves (locale, firewall, services, docker, passwordless keyring) and
   `omarchy-finalize-user` for `ps5`.
4. Login is tty1 autologin as `ps5` → `exec Hyprland`, no SDDM, matching the
   Arch / CachyOS / SteamOS images.

Omarchy's `hardware/` leaves are **not** run at build time: they are the
per-machine steps (vulkan vendor, bluetooth, wifi regdom, platform fixes), and
several of them build DKMS modules against the image kernel, which is
`linux-ps5`, not `linux-omarchy`.

## Build locally

```bash
./build_image.sh --distro omarchy
```

The `.img.xz` lands in `output/ps5-omarchy.img.xz`. `OMARCHY_CHANNEL`
(`stable`, `rc`, `edge`) selects the repo channel; it defaults to `stable`.

## Caveats

- The image ships the Omarchy *packages*. Anything the ISO wizard does outside
  them — partition layout, LUKS, `limine`/`snapper` boot and snapshot setup —
  is replaced by this repo's kexec boot flow and ext4 layout, as for every
  other PS5 image.
- Some Omarchy packages pull things that only make sense in Omarchy's own
  installer (e.g. `omarchy-settings` on `plymouth`); the Omarchy packages are
  installed with `--nodeps` so this does not fail the build, and the image
  boots with this repo's own `linux-ps5` + kexec flow rather than upstream's.
  If the transaction fails on the real image, it is the first place to look.
- Default credentials are `ps5` / `ps5` with passwordless sudo, same as the
  other images. Change them before exposing the machine to a network.
