#!/bin/bash
# oea-buildsystem entrypoint.
#
# Continuous MACHINE loop: builds every MACHINE in $MACHINES in
# round-robin, forever. After each MACHINE (success or fail) sstate +
# sources are mcli-mirrored to MinIO, deploy on success. Persistent
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
#   Write side (mcli mirror after each MACHINE, service-account write auth):
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

# --- 1b. Ensure mount roots are writable by builder --------------------
# Docker-managed named volumes initialize their mount root as root:root
# when the volume is first attached to a container. The builder user
# (uid 1000) can't write there without a one-time chown. Bind-mounts
# from an already-1000-owned host path skip this cleanly (the [ ! -w ]
# check is false). Only the top-level dir is chowned -- avoids a slow
# recursive chown over a 200 GB /temp.
for d in /temp /sstate-cache /sources /deploy; do
    if [ -d "$d" ] && [ ! -w "$d" ]; then
        echo ">>> chown $d (mount root not writable by builder)"
        sudo chown builder:builder "$d"
    fi
done

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

# --- 7. mcli (MinIO client) setup: only if all three write creds given ---
# Binary is installed as `mcli` (not `mc`) to avoid clashing with the
# Midnight Commander apt package. MinIO derives its env-var prefix
# from the invoked binary name, so the alias env-var is
# MCLI_HOST_local (not MC_HOST_local).
MC_ENABLED=0
if [ -n "${MINIO_HOST:-}" ] && [ -n "${MINIO_ACCESS_KEY:-}" ] && [ -n "${MINIO_SECRET_KEY:-}" ]; then
    export MCLI_HOST_local="http://${MINIO_ACCESS_KEY}:${MINIO_SECRET_KEY}@${MINIO_HOST}"
    MC_ENABLED=1
    echo ">>> mcli post-MACHINE sync enabled (target: ${MINIO_HOST})"
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

# SIGTERM / SIGINT: forward to bitbake for graceful shutdown. Bitbake
# stops scheduling new tasks, lets in-flight tasks finish (typically
# minutes, not the hours a full MACHINE takes), then exits. The
# current MACHINE's state file is NOT advanced, so the next `compose
# up` resumes AT this MACHINE (not after it). Any sstate + sources
# already produced during the partial run get mirrored to MinIO as
# usual on the way out.
STOP_REQUESTED=0
MAKE_PID=""
handle_stop() {
    echo ""
    echo ">>> Stop signal received -- forwarding SIGTERM to bitbake for graceful shutdown"
    echo ">>> (bitbake finishes in-flight tasks; next start resumes this MACHINE)"
    STOP_REQUESTED=1
    if [ -n "$MAKE_PID" ]; then
        # -TERM to the make process group -- catches make + bitbake children.
        kill -TERM -"$MAKE_PID" 2>/dev/null || kill -TERM "$MAKE_PID" 2>/dev/null || true
    fi
}
trap handle_stop TERM INT

# --- 10. Queue files for priority + failed-in-cycle --------------------
# Priority queue: user injects MACHINEs via `oea-retry <MACHINE>`
#   (helper script at /usr/local/bin/oea-retry). Drained BEFORE each
#   natural round-robin iteration.
# Failed-in-cycle queue: MACHINEs that failed during the current cycle
#   get one auto-retry pass at end-of-cycle, before starting the next.
PRIORITY_QUEUE=/temp/.oea-priority
FAILED_QUEUE=/temp/.oea-failed-current
mkdir -p /temp
: > "$FAILED_QUEUE"    # start fresh each container start

# --- 11. build_machine() helper ---------------------------------------
# args:  $1 = MACHINE   $2 = label (for logs)   $3 = "retry" flag
# When $3 is "retry", failures are NOT re-queued into $FAILED_QUEUE
# (prevents endless-retry storms on persistent errors -- next full
# cycle will visit this MACHINE again anyway).
build_machine() {
    local M="$1"
    local LABEL="$2"
    local IS_RETRY="${3:-}"

    echo
    echo "================================================================="
    echo "  START  MACHINE=$M  ($LABEL)"
    echo "================================================================="
    local BUILD_DIR="builds/$DISTRO/$DISTRO_TYPE/$M"
    mkdir -p "$BUILD_DIR"
    rm -rf "$BUILD_DIR/tmp"
    mkdir -p "/temp/$M" "/deploy/$M"
    ln -s "/temp/$M" "$BUILD_DIR/tmp"
    rm -rf "/temp/$M/deploy"
    ln -s "/deploy/$M" "/temp/$M/deploy"

    # Run make in its own process group so the SIGTERM handler can
    # signal the whole tree (make + bitbake workers).
    set +e
    setsid make MACHINE="$M" DISTRO="$DISTRO" DISTRO_TYPE="$DISTRO_TYPE" "$ACTION" &
    MAKE_PID=$!
    wait "$MAKE_PID"
    local RC=$?
    MAKE_PID=""
    set -e

    if [ "$RC" = "0" ]; then
        echo "================================================================="
        echo "  OK    MACHINE=$M  ($LABEL)"
        echo "================================================================="
    elif [ "$STOP_REQUESTED" = "1" ]; then
        echo "================================================================="
        echo "  STOP  MACHINE=$M  ($LABEL, bitbake shut down cleanly)"
        echo "================================================================="
    else
        echo "================================================================="
        echo "  FAIL  MACHINE=$M  ($LABEL, rc=$RC)"
        echo "================================================================="
        local COOKER_LOG
        COOKER_LOG=$(ls -1t "/temp/$M/log/cooker/$M"/*.log 2>/dev/null | head -1 || true)
        if [ -n "$COOKER_LOG" ]; then
            echo "  ERROR markers from $COOKER_LOG:"
            grep -E "^ERROR:" "$COOKER_LOG" 2>/dev/null || echo "  (no ERROR markers in log)"
        else
            echo "  (no cooker log found under /temp/$M/log/cooker/$M/)"
        fi
        # Queue for end-of-cycle retry unless this WAS the retry.
        if [ "$IS_RETRY" != "retry" ]; then
            echo "$M" >> "$FAILED_QUEUE"
            echo "  >>> queued for end-of-cycle retry"
        fi
    fi

    # --- MinIO sync (per-MACHINE, right after the build) ---
    # sstate + sources are the two shared cross-host caches. deploy
    # is intentionally NOT synced to MinIO -- artefacts live on the
    # shared oea_deploy volume and get published from there by a
    # separate downstream job (feed hosting, rsync, ...).
    if [ "$MC_ENABLED" = "1" ]; then
        echo ">>> mcli mirror sstate + sources -> MinIO"
        mcli mirror --overwrite --newer /sstate-cache/ "local/sstate-${DISTRO}-${BRANCH}/" \
            || echo "!!! sstate sync failed (continuing)"
        mcli mirror --overwrite --newer /sources/      "local/sources/" \
            || echo "!!! sources sync failed (continuing)"
    fi

    return $RC
}

# --- 12. drain_priority_queue() ---------------------------------------
# Pops MACHINEs from the priority queue file one at a time (atomic:
# read head, rewrite tail). Called before each natural iteration.
drain_priority_queue() {
    while [ -s "$PRIORITY_QUEUE" ]; do
        local PM
        PM=$(head -n 1 "$PRIORITY_QUEUE")
        tail -n +2 "$PRIORITY_QUEUE" > "${PRIORITY_QUEUE}.tmp"
        mv "${PRIORITY_QUEUE}.tmp" "$PRIORITY_QUEUE"
        echo
        echo "!!!!!! priority-queue: building MACHINE=$PM !!!!!!"
        build_machine "$PM" "priority" || true
        [ "$STOP_REQUESTED" = "1" ] && exit 0
    done
}

# --- 13. Infinite MACHINE loop ----------------------------------------
CYCLE=0
while true; do
    CYCLE=$((CYCLE + 1))
    : > "$FAILED_QUEUE"    # reset per-cycle failure tracking
    echo
    echo "================================================================="
    echo "  === CYCLE $CYCLE ==="
    echo "================================================================="

    for offset in $(seq 0 $((N - 1))); do
        # Priority queue drained first -- user-injected MACHINEs (via
        # `oea-retry`) get built before the next round-robin position.
        drain_priority_queue

        IDX=$(( (START_IDX + offset) % N ))
        M="${MACHINES_ARR[$IDX]}"

        build_machine "$M" "cycle $CYCLE, pos $((offset + 1))/$N" || true

        if [ "$STOP_REQUESTED" = "1" ]; then
            echo ">>> Stopping (next start will resume MACHINE=$M)"
            exit 0
        fi

        # Normal completion (OK or hard FAIL): mark this MACHINE done
        # so the next cycle's start-index passes it.
        echo "$M" > "$STATE_FILE"
    done

    # End-of-cycle: drain priority queue one last time (user may have
    # injected while we were on the last MACHINE), then auto-retry any
    # MACHINEs that failed this cycle.
    drain_priority_queue

    if [ -s "$FAILED_QUEUE" ]; then
        RETRY_LIST=$(cat "$FAILED_QUEUE")
        RETRY_COUNT=$(echo "$RETRY_LIST" | wc -w)
        : > "$FAILED_QUEUE"
        echo
        echo "================================================================="
        echo "  === END-OF-CYCLE RETRY PASS ($RETRY_COUNT MACHINE(s)) ==="
        echo "================================================================="
        for RM in $RETRY_LIST; do
            drain_priority_queue
            build_machine "$RM" "retry after cycle $CYCLE" "retry" || true
            [ "$STOP_REQUESTED" = "1" ] && exit 0
        done
    fi

    # Cycle complete -- next cycle starts at index 0.
    START_IDX=0
done
