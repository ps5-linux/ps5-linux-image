# Binary repackaging of pre-built kernel artifacts — no compilation here.
# Invoked by build.sh with: stagedir, kver, ver defined.
%global debug_package %{nil}
%global _build_id_links none
%global __os_install_post %{nil}
%global __strip /bin/true

Name:           linux-ps5
Version:        %{ver}
Release:        1
Summary:        PS5 Linux kernel %{kver} (image + modules + headers)
License:        GPL-2.0-only
URL:            https://kernel.org
ExclusiveArch:  x86_64
AutoReqProv:    no

Provides:       kernel = %{ver}
Provides:       kernel-core = %{ver}
Provides:       kernel-modules = %{ver}
Provides:       kernel-devel = %{ver}

%description
Linux kernel %{kver} with PlayStation 5 support patches
(https://github.com/ps5-linux/ps5-linux-patches).

%install
cp -a %{stagedir}/. %{buildroot}/

%files
/boot/vmlinuz-%{kver}
/boot/System.map-%{kver}
/boot/config-%{kver}
/usr/lib/modules/%{kver}

%post
echo ">> linux-ps5 post-install: kernel %{kver}"
depmod -a %{kver} || true

# Rebuild initramfs (hardware-independent — the build host is not the PS5)
if command -v dracut >/dev/null 2>&1; then
    echo ">> Rebuilding initramfs with dracut for %{kver}"
    dracut --force --no-hostonly "/boot/initrd.img-%{kver}" %{kver}
fi

# Copy kernel + initrd to EFI partition
if [ -d /boot/efi ]; then
    echo ">> Copying /boot/vmlinuz-%{kver} -> /boot/efi/bzImage"
    cp "/boot/vmlinuz-%{kver}" /boot/efi/bzImage
    echo ">> Copying /boot/initrd.img-%{kver} -> /boot/efi/initrd.img"
    cp "/boot/initrd.img-%{kver}" /boot/efi/initrd.img
    echo ">> Kernel %{kver} deployed to /boot/efi"
else
    echo ">> /boot/efi not found, skipping EFI deploy"
fi
