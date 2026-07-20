#!/usr/bin/env bash
# Builds the opendreambox build image (Ubuntu 18.04 + Pro/ESM).
#
# Usage:
#   ./build.sh
#   TAG=dreamos-buildsystem:test ./build.sh
#   NO_CACHE=1 ./build.sh
set -euo pipefail

TAG="${TAG:-dreamos-buildsystem-ubnt18}"
SECRET="${SECRET:-pro-attach-config.yaml}"

if [ ! -f "$SECRET" ]; then
    echo "Error: secret file '$SECRET' is missing." >&2
    echo "Copy pro-attach-config.yaml.example and enter your Ubuntu Pro token." >&2
    exit 1
fi

SOURCES_IMAGE="${SOURCES_IMAGE:-dreamos-buildsystem-sources:latest}"

if ! docker image inspect "$SOURCES_IMAGE" >/dev/null 2>&1; then
    echo "Error: sources image '$SOURCES_IMAGE' not found locally." >&2
    echo "Build it first: (cd ../dreamos-buildsystem-sources && ./build.sh)" >&2
    exit 1
fi

export DOCKER_BUILDKIT=1

BUILD_ARGS=(build .
    --build-arg "SOURCES_IMAGE=$SOURCES_IMAGE"
    --secret "id=pro-attach-config,src=$SECRET"
    -t "$TAG"
)

if [ "${NO_CACHE:-}" = "1" ]; then
    BUILD_ARGS+=(--no-cache)
fi

echo "Building $TAG ..."
docker "${BUILD_ARGS[@]}"

echo "Done. Start with: docker run --rm -it $TAG"
