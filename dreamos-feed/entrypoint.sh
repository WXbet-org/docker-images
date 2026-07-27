#!/bin/sh
# dreamos-feed entrypoint.
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
#   │               ├── all/       → <build>/.../deploy/deb/all
#   │               ├── dm900/     → <build>/.../deploy/deb/dm900
#   │               ├── <tune>/    → <build>/.../deploy/deb/<tune>
#   │               ├── Packages.gz -> <build>/.../deploy/deb/Packages.gz
#   │               ├── Release     -> <build>/.../deploy/deb/Release
#   │               ├── ...          (any other file / dir under deb/)
#   │               └── images/    → <build>/.../deploy/images/dm900
#   └── dreamlegacy/...
#
# The URL the box hits is <HOST>/<fork>/<branch>/<channel>/<machine>/<arch>/...
# which maps to /srv/feed/<fork>/<branch>/<channel>/<machine>/<arch>/... which
# is the symlink pointing into <deploy>/deb/<arch>/... -- no rewrite,
# and the URL doesn't include /deb (opkg reads the .deb repo directly
# from the machine-level URL).
#
# Images live under a sibling `images` symlink, so
# <HOST>/<fork>/<branch>/<channel>/<machine>/images/<file> serves the
# firmware image without leaking a /deb/ segment.
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
    printf '>>> dreamos-feed: %s\n' "$*" >&2
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

# Fan out the contents of <deploy>/deb into <feed>/<...>/<machine>/ as
# individual symlinks (all/, <machine>/, per-tune dirs, Packages.gz,
# Release, InRelease, Release.gpg, ...), and if <deploy>/images/<machine>
# exists, add a sibling `images` symlink to it. Idempotent -- existing
# symlinks are refreshed only if the target moved; new entries in the
# deploy dir picked up on the next rescan.
link_machine() {
    local deploy_dir="$1"
    local link_dir="$2"
    local machine="$3"

    mkdir -p "$link_dir"

    # deb feed: symlink each direct child of deploy/deb into <link_dir>.
    # Empty deploy dir is OK -- rescans will catch new entries.
    if [ -d "$deploy_dir/deb" ]; then
        for entry in "$deploy_dir/deb"/*; do
            [ -e "$entry" ] || continue
            local name
            name=$(basename "$entry")
            local link="$link_dir/$name"
            if [ ! -L "$link" ] || [ "$(readlink "$link")" != "$entry" ]; then
                ln -sfn "$entry" "$link"
            fi
        done
    fi

    # images/<MACHINE> gets its own sibling symlink named `images`.
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

# --- background rescan loop, catches newly finished builds ---
(
    while sleep "$RESCAN_INTERVAL"; do
        setup_symlinks || log "rescan failed (continuing)"
    done
) &

# --- hand off to Caddy ---
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
