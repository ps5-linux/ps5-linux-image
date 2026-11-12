#!/bin/bash
# distros/omarchy/post-install.sh — Omarchy's target-side system setup.
#
# Omarchy's own installer runs `omarchy apply system --install-user USER
# --first-install` in the installed system (see omarchy-install.sh in
# omacom/omarchy: "The ISO calls this in the target chroot after packages are
# installed and the target user exists"). That script normally lives in the
# image-builder container and is chrooted in by entrypoint.sh for an Arch
# image; distrobuilder has no such hook, so this file runs inside the built
# rootfs from image.yaml's post-files action.
#
# Declares no shebang on purpose: it is sourced, like Omarchy's own install/
# leaves.
#
# Expects in env: DISTRO=omarchy, CHROOT (the rootfs being built),
#                 plus the staging dir variables exported by image.yaml.
# Expects on disk: /omarchy-pkgs (staged packages), /omarchy-db (repo indexes)
set -eux

# --- pacman: Omarchy's stable repos + keyring --------------------------------
# Same templates Omarchy's `omarchy apply pacman` installs on x86 (stable
# channel): its own repo first, then Arch's core/extra/multilib off Omarchy's
# stable mirror.
cat > /etc/pacman.d/mirrorlist <<'EOF'
Server = https://stable-mirror.omarchy.org/$repo/os/$arch
EOF
cp /etc/pacman.conf /etc/pacman.conf.ps5-arch
sed -i '/^\[core\]$/,$d' /etc/pacman.conf
cat >> /etc/pacman.conf <<'EOF'
[omarchy]
Server = https://pkgs.omarchy.org/stable/$arch
[core]
Include = /etc/pacman.d/mirrorlist
[extra]
Include = /etc/pacman.d/mirrorlist
[multilib]
Include = /etc/pacman.d/mirrorlist
EOF

# --- Omarchy packages --------------------------------------------------------
# Installed from the staged copies: the build container has no DNS inside the
# distrobuilder chroot, so pacman cannot reach the repos here. --nodeps is
# safe for this set; their dependencies are installed (or deliberately
# omitted, see image.yaml) by the package set in the same image.yaml.
pacman-key --init
pacman-key --populate archlinux
pacman-key --populate omarchy
pacman -U --noconfirm --needed --nodeps /omarchy-pkgs/*.pkg.tar.zst || {
    # One bad package must not sink the whole image: retry without the
    # optional app packages, keeping the runtime (omarchy + settings).
    pacman -U --noconfirm --needed --nodeps \
        /omarchy-pkgs/omarchy-*.pkg.tar.zst \
        /omarchy-pkgs/omarchy-keyring-*.pkg.tar.zst
}

# --- Omarchy system setup ----------------------------------------------------
# Equivalent of `omarchy apply system --install-user <user> --first-install`,
# minus the steps that assume a live machine:
#   - pacman/ (rewrites pacman.conf from channel templates: done above),
#   - hardware/ (first-boot provisioning builds depend on the upstream
#     kernel headers),
#   - boot/ (limine + snapper; PS5 images boot through kexec).
export OMARCHY_PATH=/usr/share/omarchy
export OMARCHY_INSTALL="$OMARCHY_PATH/install"
export OMARCHY_INSTALL_USER=ps5
export OMARCHY_FIRST_INSTALL=1
export PATH="$OMARCHY_PATH/bin:$PATH"
# The ISO's fixups for machines installed through the wizard: locale files,
# passwordless keyring, service enablement, docker, firewall, browser policy.
for leaf in config/all.sh login/all.sh; do
    OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-$(basename "$(dirname "$leaf")").log \
        bash -c 'source "$OMARCHY_INSTALL/helpers/logging.sh"; start_install_log; source "$OMARCHY_INSTALL/'"$leaf"'"; stop_install_log'
done

# --- Re-apply the PS5 image's own boot + login setup -------------------------
# Omarchy's config leaves (enable-services, firewall, sddm) reset parts of the
# login path we replaced with tty1 autologin.
ln -sf /usr/lib/systemd/system/multi-user.target /etc/systemd/system/default.target
ln -sf /dev/null /etc/systemd/system/sddm.service
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ps5 --noclear %I $TERM
EOF
mkdir -p /etc/systemd/system/local-fs.target.wants
ln -sf /etc/systemd/system/grow-rootfs.service \
    /etc/systemd/system/local-fs.target.wants/grow-rootfs.service

if [ -f /usr/share/omarchy/bin/omarchy-finalize-user ]; then
    sudo -u ps5 env HOME=/home/ps5 PATH="$OMARCHY_PATH/bin:$PATH" \
        omarchy-finalize-user || true
elif [ -x /usr/local/bin/omarchy-finalize-user ]; then
    sudo -u ps5 env HOME=/home/ps5 PATH="$OMARCHY_PATH/bin:$PATH" \
        /usr/local/bin/omarchy-finalize-user || true
fi
