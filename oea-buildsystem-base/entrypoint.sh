#!/bin/bash
# oea-buildsystem entrypoint.
#
# Continuous MACHINE loop: builds every MACHINE in $MACHINES in
# round-robin, forever. After each MACHINE (success or fail) sstate +
# sources are mc-mirrored to MinIO, deploy on success. Persistent
# state file on the /temp volume tracks the last completed MACHINE
# so `docker compose stop` / `compose down` / SIGTERM cleanly finish
# the current MACHINE and the next `compose up` resumes where it
# stopped -- pause and continue between MACHINEs works out of the box.
#
# Dev / debug: attach any time via `docker compose exec oea-build bash`
# or `ssh -p 2222 builder@localhost` (password `builder`). To force a
# specific starting point, set SKIP_TO_MACHINE=<name> before starting
# the container, or edit /temp/.oea-last-machine and restart.
#
# Parameters (env-vars):
#   MACHINES              REQUIRED. Space-separated list, one make invocation each.
#                         Fallback: single MACHINE env-var.
#                         e.g. MACHINES="dm900 dm920 vuduo4k"
#   SKIP_TO_MACHINE       optional. Force first-cycle start point (overrides state file).
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

# --- 9. Resume state + graceful stop signal handling -------------------
# State file survives container restarts (lives on /temp volume).
# Records the LAST completed MACHINE so we can resume from the next
# one on restart, giving pause/stop-and-continue semantics.
STATE_FILE="/temp/.oea-last-machine"
MACHINES_ARR=($MACHINES)
N=${#MACHINES_ARR[@]}

# Where to start this container's first cycle.
START_IDX=0
if [ -n "${SKIP_TO_MACHINE:-}" ]; then
    # Explicit override -- start with this MACHINE.
    for i in "${!MACHINES_ARR[@]}"; do
        if [ "${MACHINES_ARR[$i]}" = "$SKIP_TO_MACHINE" ]; then
            START_IDX=$i
            echo ">>> SKIP_TO_MACHINE=$SKIP_TO_MACHINE (index $START_IDX)"
            break
        fi
    done
elif [ -f "$STATE_FILE" ]; then
    # Resume: pick up after the last completed MACHINE.
    LAST=$(cat "$STATE_FILE" 2>/dev/null || echo "")
    for i in "${!MACHINES_ARR[@]}"; do
        if [ "${MACHINES_ARR[$i]}" = "$LAST" ]; then
            START_IDX=$(( (i + 1) % N ))
            echo ">>> Resuming: last completed was $LAST, continuing with ${MACHINES_ARR[$START_IDX]}"
            break
        fi
    done
fi

# SIGTERM / SIGINT: finish the currently-running MACHINE cleanly then
# exit. Compose/Komodo's "stop container" is graceful this way -- no
# half-built MACHINE, and the state file points at what was completed
# last so the next start resumes correctly.
STOP_REQUESTED=0
trap 'echo ">>> Stop signal received -- will exit after current MACHINE"; STOP_REQUESTED=1' TERM INT

# --- 10. Infinite MACHINE loop (round-robin, resumable) ----------------
CYCLE=0
while true; do
    CYCLE=$((CYCLE + 1))
    echo
    echo "================================================================="
    echo "  === CYCLE $CYCLE ==="
    echo "================================================================="

    for offset in $(seq 0 $((N - 1))); do
        IDX=$(( (START_IDX + offset) % N ))
        M="${MACHINES_ARR[$IDX]}"

        echo
        echo "================================================================="
        echo "  START  MACHINE=$M  (cycle $CYCLE, position $((offset + 1))/$N)"
        echo "================================================================="
        BUILD_DIR="builds/$DISTRO/$DISTRO_TYPE/$M"
        mkdir -p "$BUILD_DIR"
        rm -rf "$BUILD_DIR/tmp"
        mkdir -p "/temp/$M" "/deploy/$M"
        ln -s "/temp/$M" "$BUILD_DIR/tmp"
        rm -rf "/temp/$M/deploy"
        ln -s "/deploy/$M" "/temp/$M/deploy"

        if make MACHINE="$M" DISTRO="$DISTRO" DISTRO_TYPE="$DISTRO_TYPE" "$ACTION"; then
            RC=0
            echo "================================================================="
            echo "  OK    MACHINE=$M  (cycle $CYCLE)"
            echo "================================================================="
        else
            RC=$?
            echo "================================================================="
            echo "  FAIL  MACHINE=$M  (cycle $CYCLE, rc=$RC)"
            echo "================================================================="
            COOKER_LOG=$(ls -1t "/temp/$M/log/cooker/$M"/*.log 2>/dev/null | head -1 || true)
            if [ -n "$COOKER_LOG" ]; then
                echo "  ERROR markers from $COOKER_LOG:"
                grep -E "^ERROR:" "$COOKER_LOG" 2>/dev/null || echo "  (no ERROR markers in log)"
            else
                echo "  (no cooker log found under /temp/$M/log/cooker/$M/)"
            fi
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

        # Persist progress -- write only AFTER the build (whether OK or
        # FAIL). An interrupted mid-build MACHINE stays unrecorded so
        # the next start re-does it from wherever it got to.
        echo "$M" > "$STATE_FILE"

        # Graceful stop check between MACHINEs.
        if [ "$STOP_REQUESTED" = "1" ]; then
            echo ">>> Stopping after $M (graceful exit)"
            exit 0
        fi
    done

    # Cycle complete -- next cycle starts at index 0.
    START_IDX=0
done
