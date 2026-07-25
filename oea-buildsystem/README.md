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

One container = one MACHINE build = one `docker run`. Exit code is
bitbake's — orchestrator can fan-in results.

```sh
docker run --rm \
    --network oea-build \
    -e MACHINE=dm900 \
    -e DISTRO=openatv \
    -e DISTRO_TYPE=release \
    -e ACTION=image \
    -e SSTATE_MIRROR_URL=http://minio:9000/sstate-openatv-6.0 \
    -e DL_MIRROR_URL=http://minio:9000/downloads \
    -v oea-sstate-dm900:/sstate-cache \
    -v oea-deploy:/deploy \
    ghcr.io/wxbet-org/oea-buildsystem:6.0
```

Full env-var + volume contract lives in [`oea-buildsystem-base`](../oea-buildsystem-base#environment-variables).
Host prerequisites (`kernel.apparmor_restrict_unprivileged_userns=0`
+ `fs.inotify.max_user_watches`) are documented there too.

## Compose stacks (Komodo / Portainer / plain compose)

Four ready-made compose files cover the two axes {batch vs dev} ×
{bind-mount vs named volume}. Pick the row that matches how you
want to run, and the column that matches where sstate/deploy
should live:

| File                                | Lifecycle                                  | Storage                     |
|-------------------------------------|--------------------------------------------|-----------------------------|
| [`docker-compose.build.volume.yaml`](docker-compose.build.volume.yaml) | one-shot: setup → `make image` → exit | Docker-managed volumes      |
| [`docker-compose.build.mount.yaml`](docker-compose.build.mount.yaml)   | one-shot: setup → `make image` → exit | Bind-mounted host paths     |
| [`docker-compose.volume.yaml`](docker-compose.volume.yaml)             | long-running: setup → `sleep infinity` | Docker-managed volumes      |
| [`docker-compose.mount.yaml`](docker-compose.mount.yaml)               | long-running: setup → `sleep infinity` | Bind-mounted host paths     |

**Batch (`.build.` variants):** container starts, entrypoint runs
`make image` for the given MACHINE, exits with bitbake's return code.
The right pick for CI / farm workers / a single-shot Komodo stack that
should tear itself down after the build.

**Dev (no `.build.` prefix):** container starts, entrypoint does its
setup (`make update`, `conf/site.conf`, sstate + deploy symlinks),
then idles on `sleep infinity`. Get a shell with
`docker compose exec oea-build bash` and drive builds by hand
(single-recipe rebuilds, `menuconfig`, iterative debug of a failing
task, ...).

Every variant needs `MACHINE` set (one MACHINE per stack). See each
file's header for the full env-var list. All variants join the
external `oea-build` docker network so the MinIO-based sstate /
downloads mirrors are reachable via hostname `minio`.

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
