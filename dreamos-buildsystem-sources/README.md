# dreamos-buildsystem-sources

Data-only container image. Contains a snapshot of the OE downloads pool (~11 GB) at `/opt/dl-mirror`. Consumed by other images (e.g. [`dreamos-buildsystem-ubnt18`](../dreamos-buildsystem-ubnt18/README.md)) as their `FROM` base — the layer is inherited by digest reference, so the 11 GB is stored **once** in the registry no matter how many downstream images use it.

## Purpose

Serves as the `PREMIRRORS` entry for bitbake in the build container. Contents mirror an accumulated OE downloads pool built up over years of opendreambox builds.

Split out from the toolchain image so:

- Toolchain updates (new packages, ESM patches) don't require moving 11 GB around.
- Sources snapshot is versioned independently and re-used across every downstream image.
- Cross-machine reuse: `docker pull` instead of rsyncing 11 GB when spinning up a new build host.

## Populating `sources-seed/`

Not in git (11 GB+, gitignored). There are two lifecycle stages:

### Initial seed

Populate once from whatever OE downloads pool you have, e.g.:

```sh
rsync -aH --info=progress2 <source-of-your-sources-pool>/ ./sources-seed/
```

### Ongoing updates from a running container

Once the toolchain image is in use, every `MACHINE=... make download` inside a container writes new fetches to `~/dreamos-builds/sources/` on the host (via the bind-mount). These are the sources that **weren't** in the current `sources-seed/` — so folding them back in enriches the mirror for future builds.

Steps on the host, with **no container currently doing a fetch** (avoid rsync racing with an active write):

```sh
# 1. Merge new files into sources-seed, skipping the symlinks that
#    point back into /opt/dl-mirror (those files are already in the
#    seed -- copying the broken symlinks would create self-references
#    in the next image).
rsync -a --safe-links --info=progress2 \
    ~/dreamos-builds/sources/ \
    ~/docker-images/dreamos-buildsystem-sources/sources-seed/

# 2. Rebuild the sources image so /opt/dl-mirror carries the new content.
cd ~/docker-images/dreamos-buildsystem-sources
./build.sh

# 3. Rebuild the toolchain image so it picks up the new sources layer
#    (its FROM base now resolves to a different digest).
cd ../dreamos-buildsystem-ubnt18
./build.sh
```

After this cycle, previously-downloaded packages become PREMIRROR hits (symlinks, zero network) instead of fresh downloads in future builds.

## Build

```sh
./build.sh                                          # -> dreamos-buildsystem-sources:latest
TAG=dreamos-buildsystem-sources:2026-07-20 ./build.sh
```

## Use as a base

In another Dockerfile:

```dockerfile
FROM dreamos-buildsystem-sources:latest
# ... your image extends here; /opt/dl-mirror is already populated ...
```

## Design notes

**Why `FROM ubuntu:18.04` and not `FROM scratch`?**
Downstream toolchain images (`dreamos-buildsystem-ubnt18`) need `ubuntu:18.04` anyway. Making the sources image extend the same base means the downstream image inherits BOTH the ubuntu base AND the sources layer via a single `FROM` — no `COPY --from` needed. A `scratch`-based sources image would force downstream images to `COPY --from`, which BuildKit re-hashes as a fresh layer → 11 GB duplicated in registry storage.

**Why `--link`?**
Keeps the 11 GB layer as a standalone overlay with a stable digest as long as `sources-seed/` content is unchanged. Downstream image rebuilds hit the cache; registry pushes reuse the existing layer.
