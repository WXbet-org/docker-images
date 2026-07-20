#!/usr/bin/env bash
# Runs the dreamos-buildsystem-ubnt18 container with the standard mount.
#
# Mount:
#   host:$HOME/dreamos-builds  ->  container:/home/builder
#
# So inside the container, the host's ~/dreamos-builds appears directly
# as the builder user's home directory. All BuildEnv checkouts and the
# shared sources/ pool persist across container restarts.
#
# The entrypoint seeds .bashrc / .profile from /etc/skel on first start
# so an empty host mount still gives a normal shell environment.
#
# Publishes SSH:
#   host:2222  ->  container:22   (login as builder / builder)
#
# Usage:
#   ./run.sh                                    # interactive bash
#   ./run.sh bootstrap-buildenv opendreambox krogoth
#   TAG=dreamos-buildsystem-ubnt18:test ./run.sh
#   SSH_PORT=2323 ./run.sh
set -euo pipefail

TAG="${TAG:-dreamos-buildsystem-ubnt18}"
SSH_PORT="${SSH_PORT:-2222}"
BUILDS_DIR="${BUILDS_DIR:-$HOME/dreamos-builds}"

mkdir -p "$BUILDS_DIR"

exec docker run --rm -it \
    -p "${SSH_PORT}:22" \
    -v "${BUILDS_DIR}:/home/builder" \
    "$TAG" "$@"
