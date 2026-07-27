#!/bin/sh
# dreamos-buildsystem-feed entrypoint.
#
# Scans the read-only build tree at /home/builder for finished builds
# and materializes a clean symlink tree under /srv/feed (which is where
# Caddy is rooted). The build tree stays untouched -- we only read.
#
# Result layout under /srv/feed:
#
#   /srv/feed/
#   ├── opendreambox/
#   │   └── krogoth/
#   │       └── <channel>/                ← from local-ext.conf
#   │           └── dm900/                ← REAL directory
#   │               ├── deb/    → <build>/.../deploy/deb
#   │               └── images/ → <build>/.../deploy/images/dm900
#   └── dreamlegacy/...
#
# The URL the box hits is <HOST>/<fork>/<branch>/<channel>/<machine>/deb/<arch>/...
# which maps to /srv/feed/<fork>/<branch>/<channel>/<machine>/deb/<arch>/... --
# the `deb` symlink follows straight into <deploy>/deb, no rewrite.
# openembedded-core's distro-feed-configs recipe writes exactly that
# URL shape (<DISTRO_FEED_URI>/deb/<arch>) into /etc/apt/sources.list.d/,
# so bootstrap-buildenv on the build side sets DISTRO_FEED_URI to the
# machine-level URL and the recipe handles the `/deb/` suffix.
#
# Firmware images live under a sibling `images` symlink, so
# <HOST>/<fork>/<branch>/<channel>/<machine>/images/<file> serves them
# without leaking into the deb repo.
#
# The scan runs once at container start (so the first HTTP request
# sees a populated tree), then loops every RESCAN_INTERVAL seconds in
# the background so newly built MACHINEs appear without a Caddy
# restart. New files INSIDE an already-symlinked subdir show up
# instantly (symlink targets are dirs, not snapshots).
set -e

BUILD_ROOT="${BUILD_ROOT:-/home/builder}"
FEED_ROOT="${FEED_ROOT:-/srv/feed}"
RESCAN_INTERVAL="${RESCAN_INTERVAL:-60}"
DEFAULT_CHANNEL="${DEFAULT_CHANNEL:-unstable}"

log() {
    printf '>>> dreamos-buildsystem-feed: %s\n' "$*" >&2
}

# Read DISTRO_FEED_CHANNEL from a branch's local-ext.conf. Fall back to
# DEFAULT_CHANNEL if the file is missing or the line isn't set.
read_channel() {
    local conf="$1/conf/local-ext.conf"
    if [ -f "$conf" ]; then
        awk -F'"' '/^[[:space:]]*DISTRO_FEED_CHANNEL[[:space:]]*[?]?=/ {print $2; exit}' "$conf" \
            | head -1 \
            | grep -E '.+' || echo "$DEFAULT_CHANNEL"
    else
        echo "$DEFAULT_CHANNEL"
    fi
}

# Materialise <feed>/<...>/<machine>/ as a real directory with two
# symlinks inside:
#
#   .../<machine>/deb    -> <deploy>/deb           (whole deb tree)
#   .../<machine>/images -> <deploy>/images/<MACHINE>  (per-machine images)
#
# The distro-feed-configs recipe on the build side writes opkg/apt
# feed URLs of the shape <URL>/deb/<arch>, so `<machine>/deb` matches
# what the box requests and gives it the whole per-arch tree in one
# symlink resolve. Images live under a sibling `images` symlink so
# they share the machine URL without leaking into the deb repo.
#
# Idempotent -- symlinks are refreshed only if their target moved;
# new files inside a linked deploy dir appear immediately since the
# symlink points at the parent, not a snapshot.
link_machine() {
    local deploy_dir="$1"
    local link_dir="$2"
    local machine="$3"

    mkdir -p "$link_dir"

    # deb repo -- single symlink covering all archs (all/, <machine>/,
    # <tune>/, Packages.gz, Release, ...). Absence is fine -- rescans
    # will pick it up as soon as the first successful package task
    # writes to the dir.
    if [ -d "$deploy_dir/deb" ]; then
        local link="$link_dir/deb"
        local target="$deploy_dir/deb"
        if [ ! -L "$link" ] || [ "$(readlink "$link")" != "$target" ]; then
            ln -sfn "$target" "$link"
        fi
    fi

    # Firmware images -- <deploy>/images/<MACHINE>. Same idempotent
    # refresh as `deb`.
    if [ -d "$deploy_dir/images/$machine" ]; then
        local link="$link_dir/images"
        local target="$deploy_dir/images/$machine"
        if [ ! -L "$link" ] || [ "$(readlink "$link")" != "$target" ]; then
            ln -sfn "$target" "$link"
        fi
    fi
}

setup_symlinks() {
    mkdir -p "$FEED_ROOT"

    # A fork dir at the top of /home/builder always contains at least
    # one branch subdir that is a git checkout. `sources/` and other
    # top-level dirs are skipped by the .git check below.
    for fork_dir in "$BUILD_ROOT"/*/; do
        [ -d "$fork_dir" ] || continue
        local fork
        fork=$(basename "$fork_dir")

        for branch_dir in "$fork_dir"*/; do
            [ -d "$branch_dir" ] || continue
            # A real branch checkout has a .git dir. Skip other subdirs.
            [ -d "$branch_dir/.git" ] || continue
            local branch
            branch=$(basename "$branch_dir")

            local build_dir="$branch_dir/build"
            [ -d "$build_dir" ] || continue

            local channel
            channel=$(read_channel "$branch_dir")

            for machine_dir in "$build_dir"/*/; do
                [ -d "$machine_dir" ] || continue
                local machine
                machine=$(basename "$machine_dir")
                local deploy_dir="$machine_dir/tmp-glibc/deploy"
                [ -d "$deploy_dir" ] || continue

                local link_dir="$FEED_ROOT/$fork/$branch/$channel/$machine"
                link_machine "$deploy_dir" "$link_dir" "$machine"
            done
        done
    done
}

# --- initial setup (blocking) so Caddy starts on a populated tree ---
setup_symlinks
log "initial scan complete"

# Caddy's {$VAR:default} placeholder falls back to the default only
# when the env-var is UNSET -- an EMPTY string is treated as a valid
# value. docker-compose always exports declared env-vars, so a
# `FEED_DOMAIN: "${FEED_DOMAIN:-}"` from an unset stack env passes an
# empty string through, which would collapse `{$FEED_DOMAIN::80}` to
# an empty site address ("server block without any key is global
# configuration"). Unset empties so the Caddyfile defaults fire.
[ -z "${FEED_DOMAIN:-}" ] && unset FEED_DOMAIN
[ -z "${FEED_ACME_EMAIL:-}" ] && unset FEED_ACME_EMAIL

# --- background rescan loop, catches newly finished builds ---
(
    while sleep "$RESCAN_INTERVAL"; do
        setup_symlinks || log "rescan failed (continuing)"
    done
) &

# --- hand off to Caddy ---
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
