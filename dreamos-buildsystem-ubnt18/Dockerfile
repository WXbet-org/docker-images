# syntax=docker/dockerfile:1.4
#
# Build image for opendreambox.
# Based on Ubuntu 18.04 + Ubuntu Pro (ESM) for security updates, plus
# the OE downloads snapshot inherited from dreamos-buildsystem-sources.
#
# The sources image must exist locally (or be pullable from a registry)
# before this build. Build it once from ../dreamos-buildsystem-sources/.
#
# Build:
#   DOCKER_BUILDKIT=1 docker build . \
#     --secret id=pro-attach-config,src=pro-attach-config.yaml \
#     -t dreamos-buildsystem-ubnt18
#
ARG SOURCES_IMAGE=dreamos-buildsystem-sources:latest
FROM ${SOURCES_IMAGE}

# Populated by CI (git SHA of the docker-images repo commit).
ARG IMAGE_COMMIT=unknown
LABEL org.opencontainers.image.source="https://github.com/WXbet-org/docker-images"
LABEL org.opencontainers.image.description="opendreambox build environment (Ubuntu 18.04 + Pro/ESM)"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.revision="${IMAGE_COMMIT}"

ENV DEBIAN_FRONTEND=noninteractive

# Stable machine-id: md5("dreamos-buildsystem-ubnt18").
# With this, Canonical recognizes repeated builds as the SAME machine
# and consumes only a single slot of your Pro token limit -- no matter
# how often you rebuild this image.
RUN echo "272a5f8626782e4844fecd4e84439e25" > /etc/machine-id \
 && mkdir -p /var/lib/dbus \
 && cp /etc/machine-id /var/lib/dbus/machine-id

# Pro attach/upgrade/install/detach/purge -- all in one RUN so that
# neither the token nor the Pro client state remain in a layer.
#
# The `trap ... EXIT` ensures that on an ABORTED build (error, Ctrl-C,
# OOM) the machine is still detached so the slot in the Ubuntu Pro
# dashboard is freed. Without it a machine would stay attached and
# occupy a slot until Canonical eventually times it out.
#
# Package list mirrors the manually-installed set from the legacy build
# server, minus unrelated projects (oscam smart-card libs, cloud/VM helpers).
RUN --mount=type=secret,id=pro-attach-config,required=true \
    set -eu; \
    trap 'pro detach --assume-yes >/dev/null 2>&1 || true' EXIT; \
    apt-get update; \
    apt-get install --no-install-recommends -y \
        ca-certificates \
        gnupg \
        locales \
        software-properties-common \
        ubuntu-advantage-tools; \
    # Locale (matches the legacy build server; bitbake expects a UTF-8 locale).
    locale-gen en_US.UTF-8; \
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; \
    # git-core PPA gives us a modern git (2.5x) instead of bionic's 2.17;
    # bitbake's git fetcher misbehaves on very old git versions.
    add-apt-repository -y ppa:git-core/ppa; \
    pro attach --attach-config /run/secrets/pro-attach-config; \
    pro status; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install --no-install-recommends -y \
        autoconf \
        autoconf-archive \
        automake \
        autopoint \
        bison \
        build-essential \
        byobu \
        bzip2 \
        chrpath \
        cmake \
        cpio \
        curl \
        cvs \
        diffstat \
        dos2unix \
        file \
        flex \
        g++ \
        g++-6 \
        gawk \
        gcc \
        gcc-6 \
        gcc-6-multilib \
        gcc-multilib \
        gettext \
        gettext-lint \
        git \
        gperf \
        help2man \
        htop \
        imagemagick \
        inkscape \
        iputils-ping \
        jq \
        lib32z1 \
        libacl1-dev \
        libcap-dev \
        libffi-dev \
        libglib2.0-dev \
        libncurses5-dev \
        libreadline-dev \
        libssl-dev \
        libtool \
        libtool-bin \
        libusb-1.0-0-dev \
        make \
        openssh-server \
        patch \
        patchelf \
        pkg-config \
        python \
        python-dev \
        python3 \
        python3-dev \
        python3-distutils \
        python3-pip \
        rsync \
        ruby \
        screen \
        sshpass \
        subversion \
        sudo \
        texi2html \
        texinfo \
        tmux \
        unzip \
        upx-ucl \
        vim \
        wget \
        xz-utils; \
    pro detach --assume-yes; \
    apt-get purge --auto-remove -y ubuntu-advantage-tools; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /var/log/ubuntu-advantage.log; \
    trap - EXIT
# Note: /etc/machine-id is INTENTIONALLY kept -- it is our stable
# recognition anchor towards Canonical and contains no secret.

# Locale env vars (must come AFTER locale-gen has run above).
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Set gcc-6 as default (the target toolchain requires exactly gcc 6.5.0).
RUN for gv in 6 7 8; do \
        if which "gcc-$gv" >/dev/null 2>&1; then \
            update-alternatives --install /usr/bin/gcc  gcc  "$(which gcc-$gv)"  "$gv" \
                                --slave   /usr/bin/g++  g++  "$(which g++-$gv)" \
                                --slave   /usr/bin/gcov gcov "$(which gcov-$gv)"; \
        fi; \
    done; \
    update-alternatives --set gcc /usr/bin/gcc-6

# Non-root user for the build (BitBake/OE refuse to build as root).
ARG BUILD_USER=builder
ARG BUILD_UID=1000
ARG BUILD_GID=1000
RUN groupadd -g "$BUILD_GID" "$BUILD_USER" \
 && useradd  -m -u "$BUILD_UID" -g "$BUILD_GID" -s /bin/bash "$BUILD_USER" \
 && echo "${BUILD_USER}:${BUILD_USER}" | chpasswd \
 && echo "$BUILD_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$BUILD_USER \
 && chmod 0440 /etc/sudoers.d/$BUILD_USER

# SSH server config: enable password auth (so builder/builder works),
# disallow root login. Host keys are generated by the entrypoint on
# first start. `/run/sshd` (tmpfs) is (re)created there too.
RUN sed -ri \
        -e 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/' \
        -e 's/^#?PermitRootLogin.*/PermitRootLogin no/' \
        -e 's/^#?UsePAM.*/UsePAM yes/' \
        /etc/ssh/sshd_config

COPY --chmod=0755 entrypoint.sh          /usr/local/bin/entrypoint.sh
COPY --chmod=0755 bootstrap-buildenv.sh  /usr/local/bin/bootstrap-buildenv

USER $BUILD_USER
WORKDIR /home/$BUILD_USER

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
