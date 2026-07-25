#!/bin/bash
# oea-buildsystem entrypoint.
#
# Runs one or more bitbake builds sequentially -- one MACHINE per
# make invocation, everything on volumes so tmp/sstate/sources/deploy
# survive container restarts. After each MACHINE finishes (success or
# fail) sstate + sources are synced to MinIO immediately, and deploy
# is synced on success. So a container that dies at MACHINE 30/50
# still leaves 29 MACHINEs worth of sstate + deploy in the shared
# store for anyone else to pick up.
#
# Parameters (env-vars):
#   MACHINES              REQUIRED. Space-separated list, one make invocation each.
#                         Fallback: single MACHINE env-var.
#                         e.g. MACHINES="dm900 dm920 vuduo4k"
#   DISTRO                default: openatv
#   DISTRO_TYPE           default: release
#   BRANCH                default: 6.0     (used for MinIO bucket naming: sstate-${DISTRO}-${BRANCH})
#   ACTION                default: image   (any make target: image, feeds, enigma2, ...)
#
# MinIO integration (all optional -- omit any block to disable that feature):
#   Read side (bitbake reads mirrors via HTTP GET, no auth needed):
#     SSTATE_MIRROR_URL   e.g. http://minio:9000/sstate-openatv-6.0
#     SOURCES_MIRROR_URL  e.g. http://minio:9000/sources
#   Write side (mc mirror after each MACHINE, service-account write auth):
#     MINIO_HOST          e.g. minio:9000
#     MINIO_ACCESS_KEY    service-account access key
#     MINIO_SECRET_KEY    service-account secret key
#
# Volumes (expected, all writable):
#   /temp                 TMPDIR per MACHINE (work, sysroots, stamps) -- huge
#   /sstate-cache         local sstate cache -- warmed from SSTATE_MIRROR_URL on miss
#   /sources              DL_DIR -- warmed from SOURCES_MIRROR_URL on miss
#   /deploy               deploy artefacts per MACHINE (kernel, rootfs, feeds)
#
# The build-enviroment Makefile writes hard-coded paths that we
# symlink onto these volumes:
#   builds/$DISTRO/sstate-cache          -> /sstate-cache        (shared across all MACHINEs)
#   builds/$DISTRO/downloads             -> /sources             (shared across all MACHINEs)
#   builds/$DISTRO/$DISTRO_TYPE/$M/tmp   -> /temp/$M             (per-MACHINE, big)
#   /temp/$M/deploy                      -> /deploy/$M           (per-MACHINE deploy on separate volume)
#
# Exit code: 0 if every MACHINE succeeded, 1 if any failed. Fail
# report at the end lists which MACHINEs and their ERROR: markers.
set -euo pipefail

# --- 1. Params + sanity ------------------------------------------------
: "${MACHINES:=${MACHINE:-}}"
: "${MACHINES:?MACHINES (or single MACHINE) is required (e.g. -e MACHINES=\"dm900 dm920\")}"
: "${DISTRO:=openatv}"
: "${DISTRO_TYPE:=release}"
: "${BRANCH:=6.0}"
: "${ACTION:=image}"

echo "================================================================="
echo "  oea-buildsystem  ($OEA_IMAGE_VERSION)"
echo "    MACHINES    = $MACHINES"
echo "    DISTRO      = $DISTRO"
echo "    DISTRO_TYPE = $DISTRO_TYPE"
echo "    BRANCH      = $BRANCH"
echo "    ACTION      = $ACTION"
echo "    SSTATE_MIRROR_URL  = ${SSTATE_MIRROR_URL:-<unset>}"
echo "    SOURCES_MIRROR_URL = ${SOURCES_MIRROR_URL:-<unset>}"
echo "    MINIO_HOST         = ${MINIO_HOST:-<unset>}"
echo "================================================================="

cd /work

# --- 2. git identity ---------------------------------------------------
git config --global --get user.email >/dev/null 2>&1 \
    || git config --global user.email "builder@oea-buildsystem.local"
git config --global --get user.name >/dev/null 2>&1 \
    || git config --global user.name  "oea-buildsystem builder"

# --- 3. Recipe refresh --------------------------------------------------
echo ">>> make update -- fetching latest recipes"
make update

# --- 4. site.conf: mirror URLs (read side) -----------------------------
mkdir -p conf
: > conf/site.conf
if [ -n "${SSTATE_MIRROR_URL:-}" ]; then
    echo "SSTATE_MIRRORS ?= \"file://.* ${SSTATE_MIRROR_URL}/PATH\"" >> conf/site.conf
fi
if [ -n "${SOURCES_MIRROR_URL:-}" ]; then
    cat >> conf/site.conf <<EOF
PREMIRRORS ?= "\\
    bzr://.*/.*      ${SOURCES_MIRROR_URL}/ \\n \\
    cvs://.*/.*      ${SOURCES_MIRROR_URL}/ \\n \\
    git://.*/.*      ${SOURCES_MIRROR_URL}/ \\n \\
    gitsm://.*/.*    ${SOURCES_MIRROR_URL}/ \\n \\
    hg://.*/.*       ${SOURCES_MIRROR_URL}/ \\n \\
    osc://.*/.*      ${SOURCES_MIRROR_URL}/ \\n \\
    p4://.*/.*       ${SOURCES_MIRROR_URL}/ \\n \\
    svn://.*/.*      ${SOURCES_MIRROR_URL}/ \\n \\
    ftp://.*/.*      ${SOURCES_MIRROR_URL}/ \\n \\
    http://.*/.*     ${SOURCES_MIRROR_URL}/ \\n \\
    https://.*/.*    ${SOURCES_MIRROR_URL}/ \\n"
EOF
fi
if [ -s conf/site.conf ]; then
    echo ">>> conf/site.conf written:"
    sed 's/^/    /' conf/site.conf
fi

# --- 5. Shared symlinks (sstate + sources are cross-MACHINE) -----------
mkdir -p "builds/$DISTRO"
rm -rf "builds/$DISTRO/sstate-cache" && ln -s /sstate-cache "builds/$DISTRO/sstate-cache"
rm -rf "builds/$DISTRO/downloads"    && ln -s /sources      "builds/$DISTRO/downloads"

# --- 6. sshd -----------------------------------------------------------
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    sudo ssh-keygen -A >/dev/null
fi
sudo mkdir -p /run/sshd
if ! pgrep -x sshd >/dev/null 2>&1; then
    sudo /usr/sbin/sshd
fi

# --- 7. mc (MinIO client) setup: only if all three write creds given ---
MC_ENABLED=0
if [ -n "${MINIO_HOST:-}" ] && [ -n "${MINIO_ACCESS_KEY:-}" ] && [ -n "${MINIO_SECRET_KEY:-}" ]; then
    export MC_HOST_local="http://${MINIO_ACCESS_KEY}:${MINIO_SECRET_KEY}@${MINIO_HOST}"
    MC_ENABLED=1
    echo ">>> mc post-MACHINE sync enabled (target: ${MINIO_HOST})"
fi

# --- 8. Passed command overrides the build loop (dev stacks) -----------
# If the container was started with a `command` (e.g. `sleep infinity`
# from a dev compose file), exec that here and skip the MACHINE loop.
# Setup above (mirrors, symlinks, sshd) has still run, so the container
# is fully wired for a manual `make MACHINE=$M image` from an exec'd
# shell.
if [ "$#" -gt 0 ]; then
    echo "================================================================="
    echo "  Setup done. Exec'ing passed command (skipping build loop):"
    echo "    $*"
    echo "================================================================="
    exec "$@"
fi

# --- 9. Per-MACHINE build + immediate MinIO sync -----------------------
OK=""
FAILED=""
FAIL_DETAIL=""

for M in $MACHINES; do
    echo
    echo "================================================================="
    echo "  START  MACHINE=$M"
    echo "================================================================="
    BUILD_DIR="builds/$DISTRO/$DISTRO_TYPE/$M"
    mkdir -p "$BUILD_DIR"
    # Wire per-MACHINE tmp/ onto /temp/$M, then tmp/deploy onto /deploy/$M.
    rm -rf "$BUILD_DIR/tmp"
    mkdir -p "/temp/$M" "/deploy/$M"
    ln -s "/temp/$M" "$BUILD_DIR/tmp"
    rm -rf "/temp/$M/deploy"
    ln -s "/deploy/$M" "/temp/$M/deploy"

    if make MACHINE="$M" DISTRO="$DISTRO" DISTRO_TYPE="$DISTRO_TYPE" "$ACTION"; then
        RC=0
        OK="$OK $M"
        echo "================================================================="
        echo "  OK    MACHINE=$M"
        echo "================================================================="
    else
        RC=$?
        FAILED="$FAILED $M"
        echo "================================================================="
        echo "  FAIL  MACHINE=$M (rc=$RC)"
        echo "================================================================="
        # bitbake writes timestamped cooker logs; grab the newest for the fail report.
        COOKER_LOG=$(ls -1t "/temp/$M/log/cooker/$M"/*.log 2>/dev/null | head -1 || true)
        if [ -n "$COOKER_LOG" ]; then
            FAIL_SUMMARY=$(grep -E "^ERROR:" "$COOKER_LOG" 2>/dev/null || echo "  (log exists but no ERROR markers: $COOKER_LOG)")
        else
            FAIL_SUMMARY="  (no cooker log found under /temp/$M/log/cooker/$M/)"
        fi
        FAIL_DETAIL="$FAIL_DETAIL

--- MACHINE=$M (rc=$RC) ---
$FAIL_SUMMARY"
    fi

    # --- MinIO sync (per-MACHINE, right after the build) ---
    if [ "$MC_ENABLED" = "1" ]; then
        echo ">>> mc mirror sstate + sources -> MinIO"
        mc mirror --overwrite --newer /sstate-cache/ "local/sstate-${DISTRO}-${BRANCH}/" \
            || echo "!!! sstate sync failed (continuing)"
        mc mirror --overwrite --newer /sources/      "local/sources/" \
            || echo "!!! sources sync failed (continuing)"
        if [ "$RC" = "0" ]; then
            echo ">>> mc mirror deploy/$M -> MinIO"
            mc mirror --overwrite --newer "/deploy/$M/" "local/deploy-${DISTRO}-${BRANCH}/$M/" \
                || echo "!!! deploy sync failed for $M"
        else
            echo ">>> skipping deploy sync for $M (build failed, artefacts may be partial)"
        fi
    fi
done

# --- 10. Report + exit code -------------------------------------------
echo
echo "================================================================="
echo "  BUILDS DONE"
[ -n "$OK"     ] && echo "    OK   :$OK"
[ -n "$FAILED" ] && echo "    FAIL :$FAILED"
echo "================================================================="
if [ -n "$FAILED" ]; then
    echo "  FAILURE DETAILS"
    echo "  (full cooker logs live at /temp/<MACHINE>/log/cooker/<MACHINE>/)"
    echo "================================================================="
    echo "$FAIL_DETAIL"
    exit 1
fi
