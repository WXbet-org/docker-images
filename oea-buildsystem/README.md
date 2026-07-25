# oea-buildsystem

The consumable OE-Alliance build-system image — what CI / build farms
actually `docker run` to produce OpenATV (and, in future, any other
`build-enviroment`-based distro) images for a given box.

Not built directly. It's composed on ghcr from two upstream pieces
via `compose.sh` in this directory:

  [`oea-buildsystem-base`](../oea-buildsystem-base) (Ubuntu +
  toolchain + entrypoint) `⊕` [`oea-buildsystem-repo`](../oea-buildsystem-repo)
  (checked-out `oe-alliance/build-enviroment` tree at some branch)
  `→` `oea-buildsystem:<branch>`.

## Tag scheme

| Tag                                    | Produced by                         | Semantics                                    |
|----------------------------------------|-------------------------------------|-----------------------------------------------|
| `oea-buildsystem:<branch>-vX.Y.Z`      | git tag `oea-buildsystem/vX.Y.Z`    | Semver milestone, pinned & immutable          |
| `oea-buildsystem:<branch>-YYYYMMDD`    | weekly cron / manual dispatch       | Periodic bake, pinned & immutable             |
| `oea-buildsystem:<branch>`             | any bake if this is the highest tag | Moving latest for that branch                 |

`<branch>` is a `build-enviroment` branch (currently only `6.0` —
upstream's default; add more via `matrix.include` in the workflow).

Consumers should pull `:<branch>` for tracking or `:<branch>-vX.Y.Z`
/ `:<branch>-YYYYMMDD` for reproducible pins.

## Usage

One container can build one MACHINE (dev) or many MACHINEs
sequentially (batch). Exit code is 0 if every MACHINE succeeded.

```sh
docker run --rm \
    --network oea-build \
    -e MACHINES="dm900 dm920" \
    -e DISTRO=openatv \
    -e BRANCH=6.0 \
    -e DISTRO_TYPE=release \
    -e ACTION=image \
    -e SSTATE_MIRROR_URL=http://minio:9000/sstate-openatv-6.0 \
    -e SOURCES_MIRROR_URL=http://minio:9000/sources \
    -e MINIO_HOST=minio:9000 \
    -e MINIO_ACCESS_KEY=builder \
    -e MINIO_SECRET_KEY=<secret> \
    -v oea_temp:/temp \
    -v oea_sstate:/sstate-cache \
    -v oea_sources:/sources \
    -v oea_deploy:/deploy \
    ghcr.io/wxbet-org/oea-buildsystem:6.0
```

After each MACHINE finishes the entrypoint mc-mirrors sstate + sources
back to MinIO (deploy too on success), so a container that dies at
MACHINE 30/50 still leaves 29 MACHINEs worth of warmth for the next.

Full env-var + volume contract lives in [`oea-buildsystem-base`](../oea-buildsystem-base#environment-variables).
Host prerequisites (`kernel.apparmor_restrict_unprivileged_userns=0`
+ `fs.inotify.max_user_watches`) are documented there too.

## Compose stacks (Komodo / Portainer / plain compose)

Four ready-made compose files cover the two axes {auto-loop vs dev} ×
{bind-mount vs named volume}:

| File                                | Lifecycle                                                                            | Storage                     |
|-------------------------------------|--------------------------------------------------------------------------------------|-----------------------------|
| [`docker-compose.build.volume.yaml`](docker-compose.build.volume.yaml) | continuous: round-robin through `$MACHINES` forever, resumable | Docker-managed volumes |
| [`docker-compose.build.mount.yaml`](docker-compose.build.mount.yaml)   | continuous: round-robin through `$MACHINES` forever, resumable | Bind-mounted host paths |
| [`docker-compose.volume.yaml`](docker-compose.volume.yaml)             | long-running idle: setup → `sleep infinity` (SSH + exec)        | Docker-managed volumes |
| [`docker-compose.mount.yaml`](docker-compose.mount.yaml)               | long-running idle: setup → `sleep infinity` (SSH + exec)        | Bind-mounted host paths |

**Auto-loop (`.build.` variants):** takes `MACHINES="dm900 dm920 …"`
and cycles through them round-robin, forever. `docker compose stop`
sends SIGTERM → entrypoint finishes the current MACHINE and exits
cleanly. `compose up` resumes from the next MACHINE via state file on
`/temp`. `docker compose pause` freezes mid-build (kernel-level, RAM
kept), `unpause` continues. For the 4-containers × 50-MACHINEs farm
pattern: deploy 4 stacks with different `-p` project names and
disjoint `MACHINES` subsets — MinIO glues them together in real time.

**Dev (no `.build.` prefix):** takes single `MACHINE=dm900`, sets up
the container, then idles without auto-building. Attach via
`docker compose exec oea-build bash` or `ssh -p 2222 builder@localhost`
(password `builder`) and drive builds by hand — for one-off recipe
debugs, `menuconfig`, poking at bitbake internals.

Either variant lets you SSH in / exec at runtime. All variants join
the external `oea-build` docker network so MinIO is reachable via
hostname `minio`. Volumes are per compose project (via `-p`) —
different project names get independent storage.

## Composition

`compose.sh` merges base + repo at the manifest level via `regctl`
cross-repo blob mount. No layer blobs are downloaded — the composed
image is built on the registry itself, seconds per composition. See
the script header for env vars + prerequisites.

Manual compose (for local testing):

```sh
BASE=ghcr.io/wxbet-org/oea-buildsystem-base:26.04 \
REPO=ghcr.io/wxbet-org/oea-buildsystem-repo:6.0 \
DST=ghcr.io/wxbet-org/oea-buildsystem:6.0-test \
    ./compose.sh
```

## Release process

- **Milestone release (base + composed together):**
  `git tag oea-buildsystem/vX.Y.Z && git push --tags` →
  one tag drives the whole pipeline. Base image gets built for
  every supported Ubuntu (`:<ubuntu>-vX.Y.Z` + moving `:<ubuntu>`),
  then composed image gets built for every {branch, ubuntu} pair
  against that FRESHLY built base (`:<branch>-vX.Y.Z` + moving
  `:<branch>` when this is the highest v-tag). Deterministic
  base↔composed pairing per release.
- **Automatic weekly compose bake:** Sunday 04:00 UTC cron.
  Skips base, runs only repo + compose against the current moving
  `:<ubuntu>` base tag. Composed tagged `:<branch>-YYYYMMDD` +
  moving `:<branch>`.
- **Automatic monthly base refresh:** 1st of month 03:00 UTC cron.
  Refreshes base apt state (`:<ubuntu>-YYYY.MM.DD` + moving
  `:<ubuntu>`). Doesn't compose -- next weekly cron picks up the
  refreshed base automatically.
- **Manual:** `workflow_dispatch` with independent `base` /
  `compose` toggles, branch dropdown, `push` toggle (default off =
  sanity build), and optional `base_tag` override for compose.

All in one workflow: [`.github/workflows/oea-buildsystem.yml`](../.github/workflows/oea-buildsystem.yml).
