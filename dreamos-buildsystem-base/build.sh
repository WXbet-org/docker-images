#!/usr/bin/env bash
# Builds the toolchain-only base image.
#
# Usage:
#   ./build.sh
#   TAG=dreamos-buildsystem-base:test ./build.sh
#   NO_CACHE=1 ./build.sh                        # force fresh apt / ESM patches
set -euo pipefail

TAG="${TAG:-dreamos-buildsystem-base:latest}"
SECRET="${SECRET:-pro-attach-config.yaml}"

if [ ! -f "$SECRET" ]; then
    echo "Error: secret file '$SECRET' is missing." >&2
    echo "Copy pro-attach-config.yaml.example and enter your Ubuntu Pro token." >&2
    exit 1
fi

export DOCKER_BUILDKIT=1

BUILD_ARGS=(build .
    --secret "id=pro-attach-config,src=$SECRET"
    -t "$TAG"
)

if [ "${NO_CACHE:-}" = "1" ]; then
    BUILD_ARGS+=(--no-cache)
fi

echo "Building $TAG ..."
docker "${BUILD_ARGS[@]}"

echo "Done. Base image ready. To get the full 'ubnt18' consumable image,"
echo "compose base + sources on ghcr via the compose-ubnt18 workflow,"
echo "or manually with the regctl recipe in dreamos-buildsystem-ubnt18/compose.sh."
