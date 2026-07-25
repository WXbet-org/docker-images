#!/bin/bash
# build-repo.sh — populate ./repo/ from oe-alliance/build-enviroment.
#
# Called before `docker build` for oea-buildsystem-repo. Clones the
# upstream repo at the requested branch, initialises all submodules
# (bitbake, openembedded-core, meta-oe-alliance, meta-openembedded,
# meta-qt5.15, ...), and hands off to `docker build`. Kept out of the
# Dockerfile because git operations aren't reproducible across
# Docker's layer cache -- doing them in the host filesystem makes the
# COPY layer deterministic.
#
# Usage:
#   ./build-repo.sh [branch]        # branch defaults to 6.0
set -euo pipefail

BRANCH="${1:-6.0}"
REPO="https://github.com/oe-alliance/build-enviroment.git"

echo ">>> Cleaning previous repo/"
rm -rf repo

echo ">>> Cloning $REPO branch $BRANCH into repo/"
git clone --recursive --branch "$BRANCH" "$REPO" repo

# .git directories are KEPT intact -- the entrypoint's `make update`
# inside the container needs them to fetch submodule updates at runtime.
# A fresh clone already writes a single well-packed pack per repo, so
# no additional repacking is worthwhile.

echo ">>> Repo ready. Size:"
du -sh repo
echo
echo ">>> Next:"
echo "    docker build -t oea-buildsystem-repo:$BRANCH --build-arg BRANCH=$BRANCH ."
