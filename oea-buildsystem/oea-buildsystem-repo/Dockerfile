# syntax=docker/dockerfile:1.4
#
# oea-buildsystem-repo — pure content layer with a checked-out
# build-enviroment repo + all submodules initialised at build time.
#
# `FROM scratch` on purpose: this image has NO runtime config (no
# ENTRYPOINT, no USER, no ENV, no CMD). Those all come from
# oea-buildsystem-base when the two are composed on ghcr via regctl.
# The repo image is only ever consumed as a layer, never run directly.
#
# Build (call ./build-repo.sh first to populate ./repo/):
#   ./build-repo.sh 6.0
#   docker build -t oea-buildsystem-repo:6.0 --build-arg BRANCH=6.0 .
#
FROM scratch

ARG BRANCH=6.0
ARG IMAGE_COMMIT=unknown
LABEL org.opencontainers.image.source="https://github.com/WXbet-org/docker-images"
LABEL org.opencontainers.image.description="build-enviroment repo (branch: pass BRANCH build-arg) -- content-only layer for the composed oea-buildsystem image"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.revision="${IMAGE_COMMIT}"
LABEL org.opencontainers.image.version="${BRANCH}"
LABEL org.opencontainers.image.branch="${BRANCH}"

# Owned by uid/gid 1000 which matches the `builder` user in the base
# image, so no chown dance is needed after composition.
COPY --chown=1000:1000 repo/ /work/
