#!/bin/bash
# oea-buildsystem entrypoint.
#
# Executes one bitbake build for one MACHINE. Refreshes the recipe tree
# via `make update` first, wires up the sstate-mirror + download-mirror
# if URLs are given, then hands off to the build-enviroment Makefile.
#
# Parameters (env-vars, since containers pass env cleanly):
#   MACHINE            required. e.g. dm900, vuduo4k, xpeedlx3
#   DISTRO             default: openatv
#   DISTRO_TYPE        default: release
#   ACTION             default: image           (any make target: image, feeds, enigma2, ...)
#   SSTATE_MIRROR_URL  optional. e.g. https://sstate.example/openatv/6.0
#   DL_MIRROR_URL      optional. e.g. https://dl.example
#
# Volume mounts (expected):
#   /sstate-cache      writable, local sstate for this container run
#   /deploy            writable, artefact drop-zone (per-MACHINE subdir)
#
# The build-enviroment Makefile writes to
#   builds/$DISTRO/$DISTRO_TYPE/$MACHINE/tmp/deploy/
# which this entrypoint symlinks to /deploy/$MACHINE before starting the
# build -- zero-copy artefact publication.
#
# On any make failure this exits non-zero so the orchestrator sees it.
set -euo pipefail

# --- 1. Sanity ---------------------------------------------------------
: "${MACHINE:?MACHINE is required (e.g. -e MACHINE=dm900)}"
: "${DISTRO:=openatv}"
: "${DISTRO_TYPE:=release}"
: "${ACTION:=image}"

echo "================================================================="
echo "  oea-buildsystem  ($OEA_IMAGE_VERSION)"
echo "    MACHINE     = $MACHINE"
echo "    DISTRO      = $DISTRO"
echo "    DISTRO_TYPE = $DISTRO_TYPE"
echo "    ACTION      = $ACTION"
echo "    SSTATE_MIRROR_URL = ${SSTATE_MIRROR_URL:-<unset>}"
echo "    DL_MIRROR_URL     = ${DL_MIRROR_URL:-<unset>}"
echo "================================================================="

cd /work

# --- 2a. Seed git identity if missing ---------------------------------
# Some OE recipes call `git am` or `git submodule update --init` which
# fail silently mid-run if git has no configured author. `--global` so
# it applies inside all submodules too.
git config --global --get user.email >/dev/null 2>&1 \
    || git config --global user.email "builder@oea-buildsystem.local"
git config --global --get user.name >/dev/null 2>&1 \
    || git config --global user.name  "oea-buildsystem builder"

# --- 2b. Recipe refresh (git submodule update on all layers) -----------
# The build-enviroment Makefile ships an `update` target that runs
# `git submodule update --init --recursive` under the hood, so we get
# the tip of every pinned layer at container-start time.
echo ">>> make update -- fetching latest recipes"
make update

# --- 3. Mirror config via conf/site.conf -------------------------------
# site.conf is auto-included by bitbake before local.conf, so anything
# we write here is honoured by every per-MACHINE build.
mkdir -p conf
: > conf/site.conf
if [ -n "${SSTATE_MIRROR_URL:-}" ]; then
    # `PATH` in SSTATE_MIRRORS is a bitbake literal that resolves to
    # the sstate object's structured path -- see bitbake docs.
    echo "SSTATE_MIRRORS ?= \"file://.* ${SSTATE_MIRROR_URL}/PATH\"" \
        >> conf/site.conf
fi
if [ -n "${DL_MIRROR_URL:-}" ]; then
    cat >> conf/site.conf <<EOF
PREMIRRORS ?= "\\
    bzr://.*/.*      ${DL_MIRROR_URL}/ \\n \\
    cvs://.*/.*      ${DL_MIRROR_URL}/ \\n \\
    git://.*/.*      ${DL_MIRROR_URL}/ \\n \\
    gitsm://.*/.*    ${DL_MIRROR_URL}/ \\n \\
    hg://.*/.*       ${DL_MIRROR_URL}/ \\n \\
    osc://.*/.*      ${DL_MIRROR_URL}/ \\n \\
    p4://.*/.*       ${DL_MIRROR_URL}/ \\n \\
    svn://.*/.*      ${DL_MIRROR_URL}/ \\n \\
    ftp://.*/.*      ${DL_MIRROR_URL}/ \\n \\
    http://.*/.*     ${DL_MIRROR_URL}/ \\n \\
    https://.*/.*    ${DL_MIRROR_URL}/ \\n"
EOF
fi
if [ -s conf/site.conf ]; then
    echo ">>> conf/site.conf written:"
    sed 's/^/    /' conf/site.conf
fi

# --- 4. Wire up the sstate-cache and deploy volumes --------------------
# Makefile hard-codes SSTATE_DIR = $(CURDIR)/builds/$(DISTRO)/sstate-cache
# and DEPLOY inside $BUILD_DIR/tmp/deploy. We steer both onto the mounted
# volumes with symlinks -- no Makefile patching required.
mkdir -p "builds/$DISTRO"
rm -rf   "builds/$DISTRO/sstate-cache"
ln -s /sstate-cache "builds/$DISTRO/sstate-cache"

BUILD_DIR="builds/$DISTRO/$DISTRO_TYPE/$MACHINE"
mkdir -p "$BUILD_DIR/tmp" "/deploy/$MACHINE"
rm -rf "$BUILD_DIR/tmp/deploy"
ln -s "/deploy/$MACHINE" "$BUILD_DIR/tmp/deploy"

# --- 4b. sshd (port 22 in-container) ----------------------------------
# Started unconditionally. Compose files decide whether to expose the
# port to the host. Auth: `builder` / `builder` (password set in the
# Dockerfile). Host keys are ephemeral -- regenerated per container
# start, so clients get a one-time host-key warning after `compose
# down/up`. Acceptable trade-off for dev; if you need persistent host
# keys, bind-mount /etc/ssh over from the host.
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    sudo ssh-keygen -A >/dev/null
fi
# sshd wants /run/sshd to exist (tmpfs, empty at container start).
sudo mkdir -p /run/sshd
# Idempotent: skip if a re-run of the entrypoint finds sshd already up.
if ! pgrep -x sshd >/dev/null 2>&1; then
    sudo /usr/sbin/sshd
fi

# --- 5. Build (or hand off to a passed command) ------------------------
# If the container was started with a `command` (docker run <img> <cmd>,
# or `command:` in compose), skip the make and exec that command with
# all setup above already done. Typical use: `command: [sleep, infinity]`
# in a dev compose file, then `docker compose exec oea-build bash`.
if [ "$#" -gt 0 ]; then
    echo "================================================================="
    echo "  Setup done (tree updated, site.conf written, sstate/deploy"
    echo "  wired). Exec'ing passed command instead of running make:"
    echo "    $*"
    echo "================================================================="
    exec "$@"
fi

echo ">>> make MACHINE=$MACHINE DISTRO=$DISTRO DISTRO_TYPE=$DISTRO_TYPE $ACTION"
make MACHINE="$MACHINE" DISTRO="$DISTRO" DISTRO_TYPE="$DISTRO_TYPE" "$ACTION"

echo "================================================================="
echo "  DONE  MACHINE=$MACHINE  ACTION=$ACTION"
echo "  Artefacts at /deploy/$MACHINE/"
echo "================================================================="
