# oea-buildsystem-base

Ubuntu + Yocto/OE-Alliance host toolchain + the shared entrypoint
that drives one bitbake build per container run.

The Ubuntu base OS is selectable at build time via the `UBUNTU_TAG`
build-arg (any valid `ubuntu:<tag>` on Docker Hub — the same apt
list currently resolves on 22.04, 24.04 and 26.04). Default is
`26.04`, matched to `build-enviroment` branch `6.0`. For older
branches (e.g. `5.6` → `22.04`) the CI workflow builds a per-Ubuntu
variant of this image; see [Adding a new Ubuntu variant](#adding-a-new-ubuntu-variant)
below.

**Content only.** No source tree lives in this image — that's the job of
[`oea-buildsystem-repo`](../oea-buildsystem-repo). At release time the
two get composed on ghcr into the consumable
[`oea-buildsystem:<branch>`](../oea-buildsystem) image (same pattern as
`dreamos-buildsystem-ubnt18`).

## Host prerequisites

Two Linux kernel / AppArmor settings that a container **cannot** flip
on its own. Bitbake's pseudo-fakeroot mechanism creates unprivileged
user namespaces and watches a large recipe tree via inotify. Without
the tweaks below builds fail with cryptic `pseudo` or `fetcher`
errors mid-recipe.

**1. Allow unprivileged user namespaces (AppArmor).**
Ubuntu 23.10+ restricts this by default; every build inside a
non-privileged container aborts at the first `do_package_*` step.
Persist the fix on the Docker host once:

```sh
echo 'kernel.apparmor_restrict_unprivileged_userns = 0' \
    | sudo tee /etc/sysctl.d/90-apparmor-userns.conf
sudo sysctl --system
```

Alternative (per-container instead of host-wide): run with
`--security-opt apparmor=unconfined`. Cleaner is the host setting.

**2. inotify watch budget.**
Default 8k-64k watches on many distros is far too low for a full
`meta-oe-alliance` tree (~100k+ files). Either bump host-wide:

```sh
echo 'fs.inotify.max_user_watches = 524288' \
    | sudo tee /etc/sysctl.d/91-inotify.conf
sudo sysctl --system
```

Or per-container: `docker run --sysctl fs.inotify.max_user_watches=524288 ...`
(equivalent `sysctls:` block in compose).

## Build

```sh
docker build -t oea-buildsystem-base:dev .                                # default ubuntu:26.04
docker build -t oea-buildsystem-base:dev --build-arg UBUNTU_TAG=22.04 .   # older
```

## Test without composition

Mount a local checkout of `build-enviroment` at `/work` and get a shell
to poke around:

```sh
docker run --rm -it \
    -v "/path/to/build-enviroment:/work" \
    -v oea-sstate-test:/sstate-cache \
    -v oea-deploy-test:/deploy \
    -e MACHINE=dm900 \
    --entrypoint bash \
    oea-buildsystem-base:dev
```

Or run a real one-shot build using the entrypoint (long — first run is
cold, no sstate):

```sh
docker run --rm \
    -v "/path/to/build-enviroment:/work" \
    -v oea-sstate-test:/sstate-cache \
    -v oea-deploy-test:/deploy \
    -e MACHINE=dm900 \
    -e DISTRO=openatv \
    -e DISTRO_TYPE=release \
    -e ACTION=image \
    oea-buildsystem-base:dev
```

## Entrypoint contract

The container is a one-shot build by default. On start it:

1. Runs `make update` in `/work` — refreshes recipe submodules to the
   pinned tips at container start time.
2. Writes `/work/conf/site.conf` with `SSTATE_MIRRORS` / `PREMIRRORS`
   lines if `SSTATE_MIRROR_URL` / `DL_MIRROR_URL` env-vars are set.
3. Symlinks `builds/$DISTRO/sstate-cache → /sstate-cache` and
   `builds/$DISTRO/$DISTRO_TYPE/$MACHINE/tmp/deploy → /deploy/$MACHINE`
   so bitbake writes directly into the mounted volumes (zero-copy).
4. Starts `sshd` on port 22 in the background (host keys ephemeral,
   regenerated per container start). Login: `builder` / `builder`.
5. If a `command:` was passed (e.g. `sleep infinity` for dev stacks),
   `exec`s it here and stops. Otherwise:
6. Runs `make MACHINE=… DISTRO=… DISTRO_TYPE=… $ACTION` and exits
   with make's return code so the orchestrator sees pass/fail.

## Environment variables

| Name | Default | Purpose |
|------|---------|---------|
| `MACHINE` | *(required)* | e.g. `dm900`, `vuduo4k`, `xpeedlx3` |
| `DISTRO` | `openatv` | distro built from `build-enviroment` (e.g. `openatv`) |
| `DISTRO_TYPE` | `release` | e.g. `release`, `experimental` |
| `ACTION` | `image` | any Makefile target: `image`, `feeds`, `enigma2`, `package-index`, ... |
| `SSTATE_MIRROR_URL` | *(unset)* | HTTP(S) sstate mirror, e.g. `https://sstate.example/openatv/6.0` |
| `DL_MIRROR_URL` | *(unset)* | HTTP(S) download mirror, e.g. `https://dl.example` |

## Volumes

| Path | Mode | Purpose |
|------|------|---------|
| `/sstate-cache` | rw | Local sstate for this container run. Read-mostly hits get served from `SSTATE_MIRROR_URL`; new objects write here. Recommend one volume per container to avoid bitbake's cross-build cleanup races. |
| `/deploy` | rw | Artefact drop-zone. Container writes to `/deploy/$MACHINE/…`. Safe to share across concurrent containers since each writes to its own MACHINE subdir. |

## When to rebuild this image

- New Ubuntu LTS lands and you want to move to it
- Yocto host-deps list changes (new required package)
- Entrypoint logic changes

**Not** when the source tree changes — that's the tree image's job.

## Adding a new Ubuntu variant

Backporting to an older `build-enviroment` branch usually means
building the same toolchain on an older Ubuntu (e.g. `5.6` → `22.04`,
`5.5` → `22.04`, `5.3` → `20.04`).

Two-step recipe:

1. **Enable the ubuntu tag in the base job.** In
   `.github/workflows/oea-buildsystem.yml`, uncomment (or add) the
   matrix entry in the `base:` job:

   ```yaml
   base:
     strategy:
       matrix:
         include:
           - ubuntu_tag: '26.04'
           - ubuntu_tag: '22.04'    # <-- new
   ```

   Push a new `oea-buildsystem/vX.Y.Z` tag; both variants get built
   and tagged (`:26.04-vX.Y.Z`, `:22.04-vX.Y.Z`) with the moving
   `:26.04` / `:22.04` tags pointing at the highest release.

2. **Pin the branch to it.** Same workflow file
   (`.github/workflows/oea-buildsystem.yml`), add an entry to the
   `compose:` job's `matrix.include`:

   ```yaml
   compose:
     strategy:
       matrix:
         include:
           - branch: '6.0'
             ubuntu_tag: '26.04'
           - branch: '5.6'
             ubuntu_tag: '22.04'      # <-- new
   ```

   The next cron (or a manual dispatch of that branch) will bake
   `oea-buildsystem-repo:5.6` and compose it against
   `oea-buildsystem-base:22.04` into `oea-buildsystem:5.6`.

If (and only if) the apt list actually needs to diverge for the
older Ubuntu — packages that were renamed, removed or don't exist
yet — copy `Dockerfile` to `Dockerfile.<ubuntu_tag>` and point the
matrix entry's `file:` at it. So far the current list resolves on
22.04, 24.04 and 26.04 unchanged, so this shouldn't be needed for
those. Ubuntu Pro/ESM is not used here — we take stock apt.
