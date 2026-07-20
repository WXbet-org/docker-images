# dreamos-buildsystem-base

Toolchain-only image for opendreambox builds: Ubuntu 18.04 + Ubuntu Pro (ESM) + full OE toolchain (gcc-6.5, Python 2.7 + 3.6, bison/flex/cmake/... + entrypoint/user setup) — **without** the ~11 GB OE downloads snapshot.

This image alone is **not** enough for a full opendreambox build (no `/opt/dl-mirror`). It's the bottom half of the split; the sources snapshot is the top half; the two are combined server-side on ghcr into the consumable [`dreamos-buildsystem-ubnt18`](../dreamos-buildsystem-ubnt18/README.md) image.

## Why split at all

- **Base rebuild** (Dockerfile change, ESM patch pull) — small, ~2 GB, fast CI (~5 min) on any GHA runner
- **Sources rebuild** — heavy, ~11 GB, done rarely on the local build server
- **Consumable rebuild** — pure registry-side manifest composition (~30 sec, no downloads)

No consumer sees this image directly. They pull `dreamos-buildsystem-ubnt18`.

## Prerequisites

Same as before: Docker + BuildKit, Ubuntu Pro token in `pro-attach-config.yaml`. See [`../dreamos-buildsystem-ubnt18/README.md`](../dreamos-buildsystem-ubnt18/README.md) for details.

## Build

```sh
./build.sh                    # -> dreamos-buildsystem-base:latest
NO_CACHE=1 ./build.sh         # force fresh apt / ESM patches
TAG=dreamos-buildsystem-base:2026-07-20 ./build.sh
```

## Publish

The **normal way** to publish is not via this image alone — push a `dreamos-buildsystem-ubnt18/vX.Y.Z` tag and the release pipeline builds base + composes ubnt18 in one workflow. Both images end up with the same version tag.

For **isolated base testing** (Dockerfile tweaks etc. without cutting a full release), trigger `dreamos-buildsystem-base` via **workflow_dispatch** from the Actions tab. It pushes `dreamos-buildsystem-base:latest` only.
