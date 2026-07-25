# syntax=docker/dockerfile:1.4
#
# oea-buildsystem-base — OS + Yocto/OE build tools + entrypoint.
#
# Content-only foundation for the composed oea-buildsystem image.
# Contains NO source tree -- that comes from the separate
# oea-buildsystem-repo image (composed via regctl at release time).
#
# Build:
#   docker build -t oea-buildsystem-base:dev .                           # default (26.04)
#   docker build -t oea-buildsystem-base:dev --build-arg UBUNTU_TAG=22.04 .   # older
#
# The Ubuntu base OS is selected at build time via UBUNTU_TAG (any
# valid `ubuntu:<tag>` on Docker Hub). This same Dockerfile is used
# for every supported Ubuntu; if a future release ever needs a
# divergent apt list (renamed packages, dropped ones, ...), copy
# this Dockerfile to `Dockerfile.<tag>` and add a matrix entry in
# the base workflow. So far the list below resolves on 22.04, 24.04
# and 26.04 unchanged.
#
# Test (once composed with a tree, but you can also mount the tree
# manually for a shell-only test):
#   docker run --rm -it \
#       -v <path-to-build-enviroment>:/work \
#       oea-buildsystem-base:dev \
#       bash
#
ARG UBUNTU_TAG=26.04
FROM ubuntu:${UBUNTU_TAG}

# ARG before FROM has global scope, but is consumed by FROM only --
# re-declare here to make UBUNTU_TAG available for the LABEL below.
ARG UBUNTU_TAG
ARG IMAGE_COMMIT=unknown
ARG IMAGE_VERSION=dev
LABEL org.opencontainers.image.source="https://github.com/WXbet-org/docker-images"
LABEL org.opencontainers.image.description="Ubuntu ${UBUNTU_TAG} + Yocto/OE-Alliance build toolchain -- base for the composed oea-buildsystem image"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.revision="${IMAGE_COMMIT}"
LABEL org.opencontainers.image.version="${IMAGE_VERSION}"
ENV OEA_IMAGE_VERSION="${IMAGE_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive

# Package list assembled explicitly from three sources:
#   1. OpenATV 8.0 README (openatv/enigma2 upstream)     -- authoritative
#   2. Curated extras (build-helpers + dev-libs picked
#      empirically from the reference build server)
#   3. Container-runtime helpers not needed on a host    -- e.g. locales
#
# Deliberately NOT included:
#   * gcc-12 pin from the OpenATV 8.0 README -- we take the distro default gcc
#   * Alternate gcc versions (gcc-15/16 side-by-side installs)
#   * Smartcard host libs (libccid, libpcsclite-dev) -- oscam builds
#     cross-compiled, host needs nothing
#   * qemu-user-binfmt, libtool-bin -- not currently needed
#   * Dev-workstation cruft (vim, nano, tmux, htop, ...); install via
#     `apt install` inside a running container if you want them
RUN apt-get update && apt-get install --no-install-recommends -y \
        autoconf \
        autoconf-archive \
        automake \
        bison \
        build-essential \
        bzip2 \
        ca-certificates \
        chrpath \
        cmake \
        coreutils \
        cpio \
        curl \
        cvs \
        debianutils \
        default-jre \
        default-jre-headless \
        devscripts \
        dialog \
        diffstat \
        dos2unix \
        equivs \
        fakeroot \
        flex \
        g++ \
        g++-multilib \
        gawk \
        gcc \
        gcc-multilib \
        gettext \
        git \
        git-lfs \
        gnupg \
        gnupg2 \
        gzip \
        help2man \
        info \
        iputils-ping \
        java-common \
        jq \
        lib32z1 \
        libacl1-dev \
        libc6-dev \
        libc6-dev-i386 \
        libcap-dev \
        libglib2.0-dev \
        libgmp3-dev \
        libmpc-dev \
        libmpfr-dev \
        libncurses-dev \
        libperl4-corelibs-perl \
        libproc-processtable-perl \
        libsdl1.2-dev \
        libserf-dev \
        libsqlite3-dev \
        libtool \
        libusb-1.0-0-dev \
        libxml2-utils \
        locales \
        lz4 \
        make \
        mc \
        meson \
        ncurses-bin \
        openssh-client \
        openssh-server \
        patch \
        patchelf \
        perl \
        pkg-config \
        ppa-purge \
        psmisc \
        python-is-python3 \
        python3 \
        python3-git \
        python3-html5lib \
        python3-jinja2 \
        python3-pexpect \
        python3-pip \
        python3-setuptools \
        quilt \
        rsync \
        socat \
        software-properties-common \
        sshpass \
        subversion \
        sudo \
        tar \
        texi2html \
        texinfo \
        unzip \
        wget \
        xsltproc \
        xterm \
        xz-utils \
        zip \
        zlib1g-dev \
        zstd \
 && locale-gen en_US.UTF-8 \
 && update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# OpenATV README explicitly requires /bin/sh to be bash -- many bitbake
# helper scripts assume bashisms and break under dash (Ubuntu default).
RUN ln -sf bash /bin/sh

# MinIO Client -- used by the entrypoint to sync sstate / sources /
# deploy back to the shared MinIO after each MACHINE build. Not in
# Ubuntu apt; fetch static binary from upstream.
#
# Installed as `mcli` (MinIO's own recommended alternate name) to
# avoid clashing with Midnight Commander (apt package `mc`) which is
# in the apt list above.
RUN curl -fsSL -o /usr/local/bin/mcli \
        https://dl.min.io/client/mc/release/linux-amd64/mc \
 && chmod 0755 /usr/local/bin/mcli

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Non-root user for the build (BitBake refuses to build as root).
# Passwordless sudo + preserve DEBIAN_FRONTEND so `sudo apt install ...`
# inside a running container stays noninteractive.
ARG BUILD_USER=builder
ARG BUILD_UID=1000
ARG BUILD_GID=1000
# Ubuntu 24.04+ ships with a pre-created `ubuntu` user at uid/gid 1000
# in the base image. It'd collide with our builder, so evict it first
# (idempotent: --force silently succeeds if the user/group is absent).
RUN if getent passwd "$BUILD_UID" >/dev/null; then \
        userdel -r -f "$(getent passwd "$BUILD_UID" | cut -d: -f1)" 2>/dev/null || true; \
    fi \
 && if getent group "$BUILD_GID" >/dev/null; then \
        groupdel -f "$(getent group "$BUILD_GID" | cut -d: -f1)" 2>/dev/null || true; \
    fi \
 && groupadd -g "$BUILD_GID" "$BUILD_USER" \
 && useradd  -m -u "$BUILD_UID" -g "$BUILD_GID" -s /bin/bash "$BUILD_USER" \
 && echo "${BUILD_USER}:${BUILD_USER}" | chpasswd \
 && printf '%s ALL=(ALL) NOPASSWD:ALL\nDefaults env_keep += "DEBIAN_FRONTEND"\n' \
        "$BUILD_USER" > /etc/sudoers.d/$BUILD_USER \
 && chmod 0440 /etc/sudoers.d/$BUILD_USER

# sshd config: password auth on (builder/builder works out of the box
# for interactive dev stacks), no root login, host keys generated by
# the entrypoint on first start.
RUN sed -ri \
        -e 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/' \
        -e 's/^#?PermitRootLogin.*/PermitRootLogin no/' \
        -e 's/^#?UsePAM.*/UsePAM yes/' \
        /etc/ssh/sshd_config

# The source tree lives here after composition. Owned by the builder user
# so `git ...` inside the container works without sudo dance.
RUN install -d -o "$BUILD_USER" -g "$BUILD_USER" /work

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0755 oea-retry.sh  /usr/local/bin/oea-retry

USER $BUILD_USER
WORKDIR /work

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
