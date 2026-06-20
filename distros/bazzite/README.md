# bazzite / bazzite-deck

Adds support for [Bazzite](https://bazzite.gg/) (uBlue's gaming-focused
atomic Fedora) and Bazzite-Deck (Steam Deck UI variant) on PS5 hardware.

These are **OCI atomic images** — distrobuilder doesn't apply.
`distros/bazzite/build-rootfs.sh` runs in place of the distrobuilder call:

1. `skopeo copy docker://ghcr.io/ublue-os/bazzite:stable` → OCI archive
2. `umoci unpack` → flat rootfs into `$CHROOT`
3. Promote `/usr/etc` defaults into `/etc`
4. Install the linux-ps5 RPM via `rpm-ostree`/`dnf`, then mask the
   rpm-ostree services (we're a flat fs now)
5. Set up grow-rootfs systemd unit + DTM-TA-race amdgpu reprobe udev rule

`bazzite-deck` is built from `ghcr.io/ublue-os/bazzite-deck:stable` via the
same script (the `case "$DISTRO" in bazzite-*)` branch generates the OCI
reference automatically).  All `distros/bazzite-deck/*` files are symlinks
into `distros/bazzite/`.

## Build locally

```bash
./build_image.sh --distro bazzite
./build_image.sh --distro bazzite-deck
```

Image size bumped to 24 GB (default).  Compressed output is large (~3-5 GB
`.img.xz`) — too big for a 2 GB GitHub release asset, so this image is not
auto-published by the CI workflow.
