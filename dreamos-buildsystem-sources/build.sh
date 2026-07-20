#!/usr/bin/env bash
# Builds the sources data image.
#
# Populate sources-seed/ once via rsync from the legacy build server
# before the first build (see README.md).
#
# Usage:
#   ./build.sh
#   TAG=dreamos-buildsystem-sources:2026-07-20 ./build.sh
set -euo pipefail

TAG="${TAG:-dreamos-buildsystem-sources:latest}"

if [ ! -d sources-seed ] || [ -z "$(ls -A sources-seed 2>/dev/null)" ]; then
    echo "Error: sources-seed/ is missing or empty." >&2
    exit 1
fi

export DOCKER_BUILDKIT=1

echo "Building $TAG ..."
docker build -t "$TAG" .

echo "Done. Use as base with:  FROM $TAG"
