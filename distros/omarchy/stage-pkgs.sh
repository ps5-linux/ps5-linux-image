#!/bin/bash
# distros/omarchy/stage-pkgs.sh — fetch the Omarchy packages and their repo
# databases into a staging directory so image.yaml can install them offline
# with `pacman -U --nodeps` (the container has no working DNS inside the
# distrobuilder chroot, and Omarchy's dependency set targets its own mirror).
#
# Usage: stage-pkgs.sh <dest-dir>
# Expects in env: OMARCHY_CHANNEL (stable|rc|edge, default stable),
#                 OMARCHY_REPO_URL, OMARCHY_MIRROR_URL
set -euo pipefail
DEST="${1:?usage: stage-pkgs.sh <dest-dir>}"
CHANNEL="${OMARCHY_CHANNEL:-stable}"
REPO_URL="${OMARCHY_REPO_URL:-https://pkgs.omarchy.org/$CHANNEL/x86_64}"
MIRROR_URL="${OMARCHY_MIRROR_URL:-https://$CHANNEL-mirror.omarchy.org}"
# Packages Omarchy's installer puts on every machine: the runtime itself plus
# the meta packages it depends on by name. Everything else comes from the
# Arch package set in image.yaml.
PACKAGES=(
    omarchy
    omarchy-settings
    omarchy-keyring
    omarchy-themes-intros
    omarchy-nvim
    omarchy-hyprland-titlebars
)
mkdir -p "$DEST/omarchy-pkgs" "$DEST/omarchy-db"
echo "=== Fetching Omarchy $CHANNEL package index ($REPO_URL) ==="
curl -fsSL -o "$DEST/omarchy-db/omarchy.db" "$REPO_URL/omarchy.db"
echo "=== Fetching $CHANNEL sync databases for offline dependency checks ==="
for repo in core extra multilib; do
    curl -fsSL -o "$DEST/omarchy-db/$repo.db" "$MIRROR_URL/$repo/os/x86_64/$repo.db" || true
done
# Resolve the newest build of each package from the index (the directory
# listing is not browsable, the db is authoritative).
resolve() {
    local pkg="$1"
    tar -tf "$DEST/omarchy-db/omarchy.db" \
        | sed -nE "s#^${pkg}-([^/]+)/desc\$#\\1#p" \
        | sort -V | tail -1
}
for pkg in "${PACKAGES[@]}"; do
    ver="$(resolve "$pkg")"
    if [ -z "$ver" ]; then
        echo "ERROR: $pkg not found in $REPO_URL/omarchy.db" >&2
        exit 1
    fi
    if [[ "$ver" == *-any ]]; then
        arch=any
    else
        arch=x86_64
    fi
    file="$pkg-$ver-$arch.pkg.tar.zst"
    echo ">> $file"
    curl -fsSL -o "$DEST/omarchy-pkgs/$file" "$REPO_URL/$file"
done
echo "=== Staged $(ls -1 "$DEST/omarchy-pkgs" | wc -l | tr -d ' ') packages in $DEST/omarchy-pkgs ==="
