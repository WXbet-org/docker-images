# oea-buildsystem-repo

Pure-content image holding a checked-out
[`oe-alliance/build-enviroment`](https://github.com/oe-alliance/build-enviroment)
repository at a specific branch, with all submodules (bitbake,
openembedded-core, meta-oe-alliance, meta-openembedded, meta-qt5.15, …)
initialised. `.git` is intentionally kept intact so the composed
image's entrypoint can `make update` at container start.

Not runnable on its own. Meant to be composed on ghcr with
[`oea-buildsystem-base`](../oea-buildsystem-base) into the final
[`oea-buildsystem:<branch>`](..) image — that's
what consumers actually pull and run.

## Tag scheme

`oea-buildsystem-repo:<branch>-<version>` (pinned) plus a moving
`oea-buildsystem-repo:<branch>` that follows the latest bake for
that branch. `<version>` is either `vX.Y.Z` (semver release) or
`YYYYMMDD` (cron/dispatch bake). Both are produced by the
[`oea-buildsystem` workflow](../.github/workflows/oea-buildsystem.yml).

## Build (manual, for testing)

```sh
./build-repo.sh 6.0
docker build -t oea-buildsystem-repo:6.0 --build-arg BRANCH=6.0 .
```

`build-repo.sh` clones `oe-alliance/build-enviroment` recursively at
the requested branch into a local `repo/` dir. Then `docker build`
does a single `COPY repo/ /work/` on top of `FROM scratch`. No
runtime metadata, no entrypoint — those come from the base image
at composition time.

## Rebuild triggers

Driven from the [`oea-buildsystem` workflow](../.github/workflows/oea-buildsystem.yml)
— this image is a byproduct of the consumable-image bake, never
built in isolation in CI. Reasons for a bake happening at all:

- Weekly cron for actively-tracked branches (currently only `6.0`) —
  keeps `make update` inside the container down to a week's delta
  and provides weekly rollback anchors.
- Semver milestone (`git tag oea-buildsystem/vX.Y.Z`) — full
  matrix bake, tagged `:<branch>-vX.Y.Z` alongside the composed
  image's `:<branch>-vX.Y.Z`.
- New OpenATV release branch cut in `build-enviroment` (`6.1`,
  `7.0`, …) → add a `matrix.include` entry
  (`{branch: 6.1, ubuntu_tag: …}`) in the workflow.

## Why `FROM scratch`

The image is a pure content-carrier — never `docker run` directly.
Composition on ghcr merges its rootfs layer into the base image's
config metadata (base supplies ENTRYPOINT / USER / ENV / WORKDIR).
Zero-config here means no leaking config drift between the two
images.
