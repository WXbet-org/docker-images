# dreamos-buildsystem-ubnt18

Consumable opendreambox build image — Ubuntu 18.04 + Pro/ESM + full OE toolchain + ~11 GB baked-in `/opt/dl-mirror` sources snapshot.

Consumer perspective:

```sh
docker pull ghcr.io/wxbet-org/dreamos-buildsystem-ubnt18:latest
docker run --rm -it \
    -p 2222:22 \
    -v ~/dreamos-builds:/home/builder \
    ghcr.io/wxbet-org/dreamos-buildsystem-ubnt18:latest
```

See the [top-level README](../README.md) for the full Quick-Start (Docker install, first-run auto-bootstrap, `make image` etc.).

## How this image is produced

It's **not built from a Dockerfile** — it's **composed on ghcr** from two existing images:

```
ghcr.io/wxbet-org/dreamos-buildsystem-base:latest        (~2 GB, toolchain, no sources)
                +
ghcr.io/wxbet-org/dreamos-buildsystem-sources:latest     (~11 GB, ubuntu + dl-mirror)
                =
ghcr.io/wxbet-org/dreamos-buildsystem-ubnt18:<version>   (~13 GB, both combined)
```

Composition uses `regctl` (regclient) at the OCI manifest level:

- Fetch manifests + configs of base and sources (kilobytes, no blob downloads)
- Diff the layer sets: identify what's in sources but not in base = the `/opt/dl-mirror` layer(s)
- Cross-repo-mount those layer blobs from the sources package into the ubnt18 package (OCI standard, server-side, zero bytes on the runner)
- Craft a new config JSON = base's runtime settings (ENV/ENTRYPOINT/USER) + sources' rootfs additions appended to `diff_ids` and `history`
- Push the composed manifest as `dreamos-buildsystem-ubnt18:<version>`

Total wall-clock: **~30 seconds** on a stock GitHub runner. No 11 GB pull, no build.

## Running the composition

**Via CI:** push a tag `dreamos-buildsystem-ubnt18/vX.Y.Z` → the `compose-ubnt18` workflow runs `compose.sh`.

**Manually** (e.g. on the build server after a manual sources refresh):

```sh
regctl registry login ghcr.io -u <you> -p <PAT_with_write_packages>

DST=ghcr.io/wxbet-org/dreamos-buildsystem-ubnt18:v0.3.0 \
    ./compose.sh

# or with explicit base/sources tags:
BASE=ghcr.io/wxbet-org/dreamos-buildsystem-base:v0.3.0 \
SOURCES=ghcr.io/wxbet-org/dreamos-buildsystem-sources:2026-07-20 \
DST=ghcr.io/wxbet-org/dreamos-buildsystem-ubnt18:v0.3.0 \
    ./compose.sh
```

## When to re-compose

- **Base rebuilt** (Dockerfile change, new ESM patches) → re-compose so ubnt18 references the new base layers
- **Sources rebuilt** (new tarballs merged into the snapshot) → re-compose so ubnt18 references the new dl-mirror layer

Either event → push a new `dreamos-buildsystem-ubnt18/vX.Y.Z` tag.

## Under the hood

- The base image supplies: ubuntu:18.04 layers, big-RUN toolchain layer, user setup, sshd config, entrypoint script, bootstrap-buildenv script
- The sources image supplies: ubuntu:18.04 layers (identical digest — shared with base, mounted once), the `/opt/dl-mirror` COPY layer
- Composed image: ubuntu + toolchain + user + entrypoint + dl-mirror — a normal single-arch container image

The composed image has base's ENV/ENTRYPOINT/CMD, so runtime behavior comes from base. Attestations from the source images are dropped (composed image is a derived artifact).

## Layout summary of the repo

```
dreamos-buildsystem-base/       ← Dockerfile lives here, CI builds it
dreamos-buildsystem-sources/    ← Dockerfile lives here, manually built on the build server
dreamos-buildsystem-ubnt18/     ← no Dockerfile -- just compose.sh + run.sh + this README
```
