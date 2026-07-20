# syntax=docker/dockerfile:1.4
#
# Data image: OE downloads snapshot (~11 GB) baked at /opt/dl-mirror.
#
# Consumed by higher-level images (e.g. dreamos-buildsystem-ubnt18) as
# their base via  FROM dreamos-buildsystem-sources:<tag>  so that the
# 11 GB layer is INHERITED by digest reference. In ghcr this means the
# layer is stored once and every derived image references it -- no
# per-image duplication.
#
# Rebuild only when the sources pool on the legacy build server actually
# changes. Toolchain updates never touch this image.
#
# Build:
#   DOCKER_BUILDKIT=1 docker build -t dreamos-buildsystem-sources:latest .
#
FROM ubuntu:18.04

LABEL org.opencontainers.image.source="https://github.com/WXbet-org/docker-images"
LABEL org.opencontainers.image.description="OE downloads snapshot (~11 GB) at /opt/dl-mirror -- base image for opendreambox build environments"
LABEL org.opencontainers.image.licenses="MIT"

# --link keeps this as its own overlay layer with a stable digest across
# rebuilds (as long as sources-seed/ content is unchanged). Requires
# BuildKit + syntax >= 1.4.
COPY --link sources-seed /opt/dl-mirror
