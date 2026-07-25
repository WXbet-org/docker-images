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
[`oea-buildsystem:<branch>`](..) image (same pattern as
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

**Host-only, no per-container fallback.** `fs.inotify.*` is a
kernel-wide (non-namespaced) sysctl — runc refuses `--sysctl` /
compose `sysctls:` for it with `"is not in a separate kernel
namespace"`. The value has to be raised on the host.

## Build

```sh
docker build -t oea-buildsystem-base:dev .                                # default ubuntu:26.04
docker build -t oea-buildsystem-base:dev --build-arg UBUNTU_TAG=22.04 .   # older
```

## Test without composition

Mount a local checkout of `build-enviroment` at `/home/builder/workspace` and get a shell
to poke around:

```sh
docker run --rm -it \
    -v "/path/to/build-enviroment:/home/builder/workspace" \
    -v oea-temp-test:/home/builder/temp \
    -v oea-sstate-test:/home/builder/sstate-cache \
    -v oea-sources-test:/home/builder/sources \
    -v oea-deploy-test:/home/builder/deploy \
    -e MACHINES=dm900 \
    --entrypoint bash \
    oea-buildsystem-base:dev
```

Or run a real one-shot build using the entrypoint (long — first run is
cold, no sstate):

```sh
docker run --rm \
    -v "/path/to/build-enviroment:/home/builder/workspace" \
    -v oea-temp-test:/home/builder/temp \
    -v oea-sstate-test:/home/builder/sstate-cache \
    -v oea-sources-test:/home/builder/sources \
    -v oea-deploy-test:/home/builder/deploy \
    -e MACHINES=dm900 \
    -e DISTRO=openatv \
    -e DISTRO_TYPE=release \
    -e ACTION=image \
    oea-buildsystem-base:dev
```

## Entrypoint contract

On container start:

1. Runs `make update` in `/home/builder/workspace` — refreshes recipe submodules to their
   pinned tips.
2. Writes `/home/builder/workspace/conf/site.conf` with `DL_DIR` / `SSTATE_DIR` + `SSTATE_MIRRORS` / `PREMIRRORS`
   lines if `SSTATE_MIRROR_URL` / `SOURCES_MIRROR_URL` are set.
3. `chown`s the four volume mount roots (`/home/builder/temp`,
   `/home/builder/sstate-cache`, `/home/builder/sources`,
   `/home/builder/deploy`) if they're not already writable by
   `builder` — Docker-managed volumes initialize root-owned;
   host-side bind-mounts already at uid 1000 skip this cleanly.
4. Starts `sshd` on port 22 (host keys ephemeral, one-time client
   warning per container recreate). Login: `builder` / `builder`.
5. If a `command:` was passed (dev stacks pass `sleep infinity`),
   `exec`s it here and skips the build loop. Otherwise:
6. Determines the resume point:
   - `SKIP_TO_MACHINE=<name>` → force that as start
   - else state file `/home/builder/temp/.oea-last-machine` → resume with next
   - else start at first MACHINE in `$MACHINES`
7. Enters an **infinite** round-robin loop through `$MACHINES`. For
   each MACHINE `$M`:
   - Symlinks per-MACHINE paths: `builds/$DISTRO/$DISTRO_TYPE/$M/tmp`
     → `/home/builder/temp/$M`, then `/home/builder/temp/$M/deploy` → `/home/builder/deploy/$M`.
   - Runs `make MACHINE=$M DISTRO=$DISTRO DISTRO_TYPE=$DISTRO_TYPE $ACTION`.
   - If MinIO write creds are set: `mcli mirror` sstate + sources
     (success or fail — the intermediate blobs are useful either
     way). Deploy is NOT mirrored — artefacts stay on the shared
     `oea-buildsystem_deploy` volume for a downstream publishing job.
   - If bitbake exited cleanly (RC=0 or hard fail): writes `$M` to
     `/home/builder/temp/.oea-last-machine` so the next cycle passes this MACHINE.
   - If bitbake exited because of a SIGTERM we forwarded to it (see
     stop semantics below): does NOT write the state file, then exits
     0 cleanly. Next start resumes AT this MACHINE.
8. When `$MACHINES` is exhausted, cycles back to index 0 forever.

**Retrying failed MACHINEs mid-cycle:**

- **Auto-retry at end of cycle** — any MACHINE that fails during
  cycle N is queued and re-attempted once before cycle N+1 starts.
  Catches transient upstream / network glitches without operator
  intervention. If the retry also fails, the MACHINE is not queued
  again this cycle (avoids retry storms on persistent errors — the
  next full cycle will visit it in its normal round-robin slot).
- **Priority queue via `oea-retry`** — inside the container:
  ```
  oea-retry dm900              # queue one
  oea-retry dm900 dm920        # queue several, processed in order
  oea-retry --list             # show queue
  oea-retry --clear            # empty queue
  ```
  Attach with `docker compose exec oea-build oea-retry dm900` or
  over SSH. The queue is drained before each natural round-robin
  iteration — the currently-running build is NOT interrupted, but
  your MACHINE(s) go next.

**Stop / pause:**

- `docker compose stop` → SIGTERM to PID 1 → entrypoint forwards it to
  the running bitbake process group. Bitbake stops scheduling new
  tasks, lets in-flight tasks finish (typically minutes), then exits.
  The container exits 0 cleanly. `compose up` resumes at the same
  MACHINE (bitbake picks up on task-stamp resume — completed tasks
  are cached, only unfinished ones re-run).
- `docker compose pause` → cgroup freezer suspends all processes
  instantly, no CPU, memory retained. `unpause` continues mid-task.

`stop_grace_period` in the compose files is 30 min — generous headroom
for the slowest single OE task (kernel compile, big Qt bits). If a
task truly can't finish in 30 min, Docker escalates to SIGKILL and we
lose those tasks — same effect as a hard crash, next start redoes
this MACHINE from the last completed task stamp.

## Environment variables

| Name | Default | Purpose |
|------|---------|---------|
| `MACHINES` | *(required)* | Space-separated list, e.g. `"dm900 dm920 vuduo4k"`. Fallback: single `MACHINE=`. |
| `SKIP_TO_MACHINE` | *(unset)* | Force first-cycle start point (overrides state file). |
| `DISTRO` | `openatv` | Distro built from `build-enviroment`. |
| `DISTRO_TYPE` | `release` | e.g. `release`, `experimental`. |
| `BRANCH` | `6.0` | `build-enviroment` branch. Used for MinIO bucket naming (`sstate-${DISTRO}-${BRANCH}`). |
| `ACTION` | `image` | Any Makefile target: `image`, `feeds`, `enigma2`, `package-index`, … |
| `SSTATE_MIRROR_URL` | *(unset)* | Read-side sstate mirror, e.g. `http://minio:9000/sstate-openatv-6.0`. |
| `SOURCES_MIRROR_URL` | *(unset)* | Read-side sources mirror, e.g. `http://minio:9000/sources`. |
| `MINIO_HOST` | *(unset)* | Write-side host, e.g. `minio:9000`. Enables `mcli mirror` when set together with the two keys below. |
| `MINIO_ACCESS_KEY` | *(unset)* | Service-account access key with `readwrite` on the sstate + sources buckets. |
| `MINIO_SECRET_KEY` | *(unset)* | Corresponding secret key. |

## Volumes

| Path | Purpose | Typical size |
|------|---------|--------------|
| `/home/builder/temp` | TMPDIR — per-MACHINE subdirs (`/home/builder/temp/$M/work`, `/home/builder/temp/$M/sysroots-*`, `/home/builder/temp/$M/stamps`). Persistent so a killed container's build state survives for debug. | 50-200 GB across all MACHINEs |
| `/home/builder/sstate-cache` | Local sstate cache — shared across MACHINEs in this container. Warmed via `SSTATE_MIRROR_URL` on cache-miss, written back via `mcli mirror` after each MACHINE. | 5-50 GB |
| `/home/builder/sources` | DL_DIR — upstream source tarballs, shared across MACHINEs. Same read/write flow as sstate. | 2-20 GB |
| `/home/builder/deploy` | Deploy artefacts (kernel, rootfs, `.ipk` feeds) per-MACHINE subdir (`/home/builder/deploy/$M/`). Shared external volume `oea-buildsystem_deploy` on the host; published downstream (feed hosting, rsync) by a separate job. Not synced to MinIO. | 1-10 GB per MACHINE |

## When to rebuild this image

- New Ubuntu LTS lands and you want to move to it
- Yocto host-deps list changes (new required package)
- Entrypoint logic changes

**Not** when the source tree changes — that's the tree image's job.

## `mc` naming note

Two different `mc` tools show up here:

- **`mc`** (from apt) — [Midnight Commander](https://midnight-commander.org),
  the terminal file manager. Useful when you `ssh -p 2222 builder@…`
  into a running container to poke around `/home/builder/temp/<MACHINE>/work/…`.
- **`mcli`** (curl'd from `dl.min.io`) — MinIO Client, used by the
  entrypoint for post-MACHINE sync. Installed under this alternate
  name (documented by MinIO) precisely to avoid clashing with
  Midnight Commander. Env-var prefix becomes `MCLI_*`
  (`MCLI_HOST_local`, etc.), not `MC_*`.

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
