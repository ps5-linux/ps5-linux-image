FROM --platform=linux/amd64 fedora:44

# Only packaging tools needed — kernel is already compiled
RUN dnf install -y rpm-build kmod && dnf clean all

WORKDIR /out/staging

# Pre-built artifacts are bind-mounted at /out/staging
# Output packages go to /out

COPY docker/kernel-builder-rpm/build.sh /build.sh
COPY docker/kernel-builder-rpm/linux-ps5.spec /linux-ps5.spec
RUN chmod +x /build.sh

CMD ["/build.sh"]
