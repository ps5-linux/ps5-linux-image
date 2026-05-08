FROM --platform=linux/amd64 archlinux:latest

# pacman 7+ sandbox doesn't work in Docker containers
RUN echo 'DisableSandbox' >> /etc/pacman.conf

# Only packaging tools needed — kernel is already compiled
RUN pacman -Syu --noconfirm && pacman -S --noconfirm \
    zstd libarchive && \
    pacman -Scc --noconfirm

WORKDIR /out/staging

# Pre-built artifacts are bind-mounted at /out/staging
# Output packages go to /out

COPY docker/kernel-builder-arch/build.sh /build.sh
RUN chmod +x /build.sh

CMD ["/build.sh"]
