# oea-buildsystem

Consumable OE-Alliance build-system image — Ubuntu + Yocto/OE
toolchain + a checked-out `oe-alliance/build-enviroment` tree, all
wired up for continuous MACHINE-loop builds with per-MACHINE MinIO
sync. Primary use: OpenATV, but works for any distro built from that
tree.

Not built from a Dockerfile — composed on ghcr from two pieces:

  [`oea-buildsystem-base`](./oea-buildsystem-base) (Ubuntu +
  toolchain + entrypoint + `mcli` + `oea-retry`) `⊕`
  [`oea-buildsystem-repo`](./oea-buildsystem-repo) (checked-out
  `build-enviroment` tree at a specific branch) `→`
  `oea-buildsystem:<branch>`.

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

## Quickstart

### 1. Host prerequisites

Two kernel settings a container can't flip on its own:

```sh
sudo tee /etc/sysctl.d/90-oea-build.conf > /dev/null <<'EOF'
kernel.apparmor_restrict_unprivileged_userns = 0
fs.inotify.max_user_watches = 524288
EOF
sudo sysctl --system
```

The first lets bitbake's pseudo-fakeroot mechanism create user
namespaces. The second raises inotify watches for the ~100k-file
recipe tree. Without either, builds fail mid-`do_package_*` with
cryptic pseudo / fetcher errors. See
[`oea-buildsystem-base`](./oea-buildsystem-base#host-prerequisites)
for full detail.

### 2. Deploy the shared MinIO stack (once per farm)

The build containers write sstate + sources back to MinIO after each
MACHINE (deploy artefacts stay on a shared Docker volume, not
MinIO). Deploy the MinIO stack first — details and one-time bucket
setup in [`minio/README.md`](./minio/README.md).

TL;DR:

```sh
docker network create oea-build
cd minio
MINIO_ROOT_PASSWORD='choose-something-strong' docker compose up -d
# then follow minio/README.md → "First-time bucket setup"
```

You'll end up with buckets `sstate-openatv-6.0` and `sources`, plus
a service account (`builder` + secret key) that the build containers
use.

You also need one shared Docker volume for sources (URL-content-
addressed, safe to share across all oea stacks on this host):

```sh
docker volume create oea-buildsystem_sources
# fix ownership so builder (uid 1000) can write:
docker run --rm --user 0:0 -v oea-buildsystem_sources:/x \
    alpine chown -R 1000:1000 /x
```

Deploy artefacts (per-MACHINE kernel/rootfs/feeds) live inside each
stack's own `temp` volume at `builds/.../$M/tmp/deploy/` and are NOT
shared -- pseudo's fd-tracking crashes across a symlink+cross-volume
boundary in `do_package_write_ipk`. Reproduce from sstate on demand.

### 3. Pick a compose stack + deploy

Four ready-made compose files cover the two axes {auto-loop vs dev}
× {bind-mount vs named volume}:

| File                                | Lifecycle                                                                | Storage                     |
|-------------------------------------|--------------------------------------------------------------------------|-----------------------------|
| [`docker-compose.build.volume.yaml`](docker-compose.build.volume.yaml) | continuous: round-robin through `$MACHINES` forever, resumable | Docker-managed volumes |
| [`docker-compose.build.mount.yaml`](docker-compose.build.mount.yaml)   | continuous: round-robin through `$MACHINES` forever, resumable | Bind-mounted host paths |
| [`docker-compose.volume.yaml`](docker-compose.volume.yaml)             | long-running idle: setup → `sleep infinity` (SSH + exec)                 | Docker-managed volumes |
| [`docker-compose.mount.yaml`](docker-compose.mount.yaml)               | long-running idle: setup → `sleep infinity` (SSH + exec)                 | Bind-mounted host paths |

**Auto-loop (`.build.` variants)** — takes `MACHINES="dm900 dm920 …"`
and cycles round-robin, forever. This is what you want for a farm
worker. Minimum viable deploy:

```sh
export MACHINES="dm900 dm920"
export MINIO_HOST=minio:9000
export MINIO_ACCESS_KEY=builder
export MINIO_SECRET_KEY=<the-secret-from-minio-setup>
export SSTATE_MIRROR_URL=http://minio:9000/sstate-openatv-6.0
export SOURCES_MIRROR_URL=http://minio:9000/sources

docker compose -p oea-a -f docker-compose.build.volume.yaml up -d
docker compose -p oea-a -f docker-compose.build.volume.yaml logs -f
```

**Dev variants** — takes a single `MACHINE=`, sets everything up,
then idles. Attach to drive builds by hand:

```sh
MACHINE=dm900 docker compose -f docker-compose.volume.yaml up -d
docker compose -f docker-compose.volume.yaml exec oea-build bash
# or:
ssh -p 2222 builder@localhost         # password: builder
```

## Runtime operations

All four variants expose sshd on `${SSH_PORT:-2222}`, so you can
attach at any time — including during a batch loop.

### Attach

```sh
docker compose -p oea-a exec oea-build bash        # via docker
ssh -p 2222 builder@<host>                         # via ssh (password: builder)
```

Komodo / Portainer provide a web-terminal button that does the exec
for you.

### Retry a failed MACHINE

Two mechanisms:

**Auto-retry at end of cycle** — any MACHINE that failed during cycle
N is queued and re-attempted once before cycle N+1 starts. Catches
transient upstream / network glitches without operator intervention.
If the retry also fails the MACHINE is not queued again this cycle
(next full cycle will visit it in its normal round-robin slot).

**Priority queue via `oea-retry`** — for "do it NOW, not at
end-of-cycle":

```sh
docker compose exec oea-build oea-retry dm900               # queue one
docker compose exec oea-build oea-retry dm900 dm920         # multiple
docker compose exec oea-build oea-retry --list              # show queue
docker compose exec oea-build oea-retry --clear             # empty queue
```

Currently-running build is not interrupted; queued MACHINE(s) go next.

### Change the MACHINE list

Edit the stack's `MACHINES=…` env-var and `compose up -d` again —
Docker recreates the container with the new list, entrypoint's state
file (`workspace/builds/$DISTRO/$DISTRO_TYPE/.oea-last-machine`) is preserved so the resume logic
picks the next matching MACHINE.

### Stop / pause

- **`docker compose stop`** — SIGTERM to PID 1 → entrypoint forwards
  to the running bitbake process group. Bitbake stops scheduling new
  tasks, lets in-flight tasks finish (minutes, not hours), exits.
  `compose up` resumes AT the same MACHINE (bitbake task-stamp
  resume — completed tasks skipped, unfinished ones re-run). Grace
  period configured to 30 min in the compose files.
- **`docker compose pause`** — cgroup freezer suspends all processes
  instantly, no CPU, memory kept. `unpause` continues mid-task. For
  quick "host needs the CPU back NOW" scenarios.
- **`docker compose down`** — stop + remove containers. Volumes
  persist, so `up` on the same project name resumes clean.

## Farm pattern: multiple parallel stacks

Split a MACHINE workload across N stacks. Two axes:

- **Same host, multiple stacks** — set `STACK=a`, `STACK=b`, ...
  to keep container names + hostnames unique (they template to
  `oea-builder-auto-${STACK:-a}`). Also unique `SSH_PORT` per stack
  since ports are host-scoped. Different `-p` project names for
  isolated per-project volumes (temp + sstate).
- **Multi-host farm** — every host runs one (or more) stacks. Host
  scope avoids container-name collision automatically, but you
  still want distinct `STACK` values for meaningful `docker ps`
  output. MinIO ties them together.

### 4 parallel stacks on 4 hosts

```sh
# Host 1
STACK=a \
MACHINES="$(cat machines/farm-a.txt)" \
MINIO_HOST=minio.internal:9000 \
MINIO_ACCESS_KEY=builder \
MINIO_SECRET_KEY=<secret> \
SSTATE_MIRROR_URL=http://minio.internal:9000/sstate-openatv-6.0 \
SOURCES_MIRROR_URL=http://minio.internal:9000/sources \
docker compose -p oea-a -f docker-compose.build.volume.yaml up -d

# Host 2 → STACK=b + -p oea-b + machines/farm-b.txt
# Host 3 → STACK=c + -p oea-c
# Host 4 → STACK=d + -p oea-d
```

### 2 stacks on ONE beefy host

```sh
# Stack a
STACK=a SSH_PORT=2222 MACHINES="dm900 dm920" \
    docker compose -p oea-a -f docker-compose.build.volume.yaml up -d

# Stack b (distinct STACK + distinct SSH_PORT!)
STACK=b SSH_PORT=2223 MACHINES="vuduo4k gbquad4k" \
    docker compose -p oea-b -f docker-compose.build.volume.yaml up -d
```

Container names: `oea-builder-auto-a` and `oea-builder-auto-b`. Both
share the external `oea-buildsystem_sources` volume on the host;
per-stack `<project>_temp` + `<project>_sstate` stay isolated (deploy
lives inside each stack's `<project>_temp`).

Each stack cycles its own subset independently. When host A finishes
`qtbase-native` for `dm900`, the resulting sstate blob is on MinIO
within seconds; when host B needs the same blob for `dm920` an hour
later, it fetches once via HTTP instead of rebuilding.

If a host dies mid-cycle: volumes stay, `compose up` on the same
project resumes at the interrupted MACHINE via the state file, and
MinIO already has whatever completed MACHINEs contributed.

## MinIO integration

Configure the container to talk to MinIO via env-vars — no config
file, no volume mount:

| Env-var | Purpose |
|---|---|
| `SSTATE_MIRROR_URL` | Read-side sstate mirror. Written into `SSTATE_MIRRORS` in `conf/site.conf`. bitbake fetches missing sstate blobs from here via HTTP GET (no auth needed if the bucket has anonymous-read policy). |
| `SOURCES_MIRROR_URL` | Read-side sources mirror. Written into `PREMIRRORS` in `conf/site.conf`. Same anonymous-read pattern. |
| `MINIO_HOST` | Write-side host, e.g. `minio:9000`. Enables per-MACHINE `mcli mirror` when set together with the two keys below. |
| `MINIO_ACCESS_KEY` | Service-account access key (typically `builder`). |
| `MINIO_SECRET_KEY` | Corresponding secret key. |

All three write-side vars must be set together to enable sync;
otherwise the entrypoint skips it silently and the container just
uses whatever's on its local volumes (still functional, just no
cross-container sharing).

**Sync flow** — after each MACHINE, whether success or fail:

```
mcli mirror --overwrite --newer /sstate-cache/  local/sstate-openatv-6.0/
mcli mirror --overwrite --newer /sources/       local/sources/
```

sstate and sources are always synced — even a failed MACHINE has
produced some intermediate sstate blobs and source fetches that are
useful to the next attempt.

Deploy artefacts (`.ipk` feeds, kernel, rootfs) are NOT synced to
MinIO. They live inside each stack's own `<project>_temp` volume at
`builds/.../$M/tmp/deploy/` — extract via `docker cp` / `docker run
--volumes-from` or a separate publishing job (feed hosting, rsync,
... — TBD). Deploy is per-stack, not shared: pseudo's fd-tracking
crashes across a symlink+cross-volume boundary in `do_package_write_ipk`,
so `tmp/deploy/` must sit on the same filesystem as `tmp/work/`.
Artefacts are cheap to reproduce from sstate when needed.

Full bucket setup + service account creation in
[`minio/README.md`](./minio/README.md).

## Debug patterns

### State file — where the loop stands right now

Inside the container:

```sh
BR=/home/builder/workspace/builds/openatv/release   # for the default DISTRO/DISTRO_TYPE
cat $BR/.oea-last-machine        # last MACHINE that completed (OK or FAIL)
cat $BR/.oea-failed-current      # MACHINEs failed this cycle, pending retry
cat $BR/.oea-priority            # MACHINEs queued via `oea-retry`
```

### Bitbake cooker logs

Per-MACHINE, timestamped, on the `<project>_temp` volume:

```sh
ls -1t $BR/<MACHINEDIR>/tmp/log/cooker/<MACHINEDIR>/*.log | head
grep -E '^ERROR:' $BR/<MACHINEDIR>/tmp/log/cooker/<MACHINEDIR>/<latest>.log
```

(`<MACHINEDIR>` = the resolved MACHINE dir, e.g. `gb7252` for
MACHINEBUILDs `gbquad4kpro` / `gbquad4k` / `gbue4kpro`.)

### Inspect / poke a failed recipe

The loop container has Midnight Commander in it (`mc`) for
comfortable navigation:

```sh
ssh -p 2222 builder@<host>
cd $BR/<MACHINEDIR>/tmp/work/<PACKAGEARCH>/<recipe>/<version>-<PR>/
mc
```

Or just `less` around under `temp/`.

### Debug a MACHINE with the batch loop still running

The batch container has SSH + exec — you don't need a separate dev
stack. Two ways:

- **Interactive shell alongside the loop**: `docker compose exec
  oea-build bash`. `make` invocations here would collide with the
  loop's per-MACHINE symlinks, so don't run `make image` in parallel.
  For inspection, tail logs, edit files: fine.
- **Take the loop down, dev up on the same volumes**: `docker
  compose -p <same-project> down`, then `MACHINE=<M> docker compose
  -f docker-compose.volume.yaml -p <same-project> up -d`. Same
  named volumes attach, dev container has all the state ready.

## Env-var reference

Full contract lives in
[`oea-buildsystem-base`](./oea-buildsystem-base#environment-variables)
— the base image's entrypoint is what actually reads these. Quick
lookup:

| Name | Default | Purpose |
|---|---|---|
| `MACHINES` | *(required)* | Space-separated list, e.g. `"dm900 dm920"`. Fallback: single `MACHINE=`. |
| `SKIP_TO_MACHINE` | *(unset)* | Force first-cycle start point (overrides state file). |
| `DISTRO` | `openatv` | Distro built from `build-enviroment`. |
| `DISTRO_TYPE` | `release` | e.g. `release`, `experimental`. |
| `BRANCH` | `6.0` | `build-enviroment` branch (for MinIO bucket naming). |
| `ACTION` | `image` | Any Makefile target: `image`, `feeds`, `enigma2`, `package-index`, … |
| `SSTATE_MIRROR_URL` | *(unset)* | Read-side sstate mirror (HTTP GET, no auth). |
| `SOURCES_MIRROR_URL` | *(unset)* | Read-side sources mirror. |
| `MINIO_HOST` | *(unset)* | Write-side host, e.g. `minio:9000`. |
| `MINIO_ACCESS_KEY` | *(unset)* | Service-account access key. |
| `MINIO_SECRET_KEY` | *(unset)* | Corresponding secret key. |
| `SSH_PORT` | `2222` | Host port for sshd. |

Volumes: `/home/builder/workspace/builds/$DISTRO/$DISTRO_TYPE` (TMPDIR,
per-MACHINE subdirs, incl. `tmp/deploy/`),
`/home/builder/sstate-cache` (local sstate), `/home/builder/sources`
(DL_DIR). See base README for size expectations. Baked tree lives at
`/home/builder/workspace/` — that's where `make MACHINE=... image`
runs from.

## Notes for constrained hosts (WSL2, small VMs)

Same underlying OE gotcha as in
[dreamos-buildsystem-ubnt18](../dreamos-buildsystem-ubnt18/README.md#4-notes-for-constrained-hosts-wsl2-small-vms):
recipes like `boost` / `qtwebkit` allocate 1-2 GB per `cc1plus`, and
default `PARALLEL_MAKE` from `nproc` OOM-kills the compiler on
< 12 GB hosts. Cap it in `local.conf` (or `conf/site.conf` which the
entrypoint writes — carefully so mirror lines are not overwritten):

```sh
# ~8 GB host:
BB_NUMBER_THREADS = "3"
PARALLEL_MAKE     = "-j 4"

# ~16 GB host, only cap the known hogs:
PARALLEL_MAKE_pn-boost           = "-j 4"
PARALLEL_MAKE_pn-boost-native    = "-j 4"
PARALLEL_MAKE_pn-qtwebkit        = "-j 4"
PARALLEL_MAKE_pn-qtwebkit-native = "-j 4"
```

## Composition

`compose.sh` merges base + repo at the manifest level via `regctl`
cross-repo blob mount — no layer blobs downloaded, composition takes
seconds on the CI runner.

Manual compose (local testing):

```sh
BASE=ghcr.io/wxbet-org/oea-buildsystem-base:26.04 \
REPO=ghcr.io/wxbet-org/oea-buildsystem-repo:6.0 \
DST=ghcr.io/wxbet-org/oea-buildsystem:6.0-test \
    ./compose.sh
```

## Release process

- **Milestone release (base + composed together):**
  `git tag oea-buildsystem/vX.Y.Z && git push --tags` →
  one tag drives the whole pipeline. Base image gets built for every
  supported Ubuntu (`:<ubuntu>-vX.Y.Z` + moving `:<ubuntu>`), then
  composed image gets built for every {branch, ubuntu} pair against
  that freshly-built base (`:<branch>-vX.Y.Z` + moving `:<branch>`
  when this is the highest v-tag). Deterministic base↔composed
  pairing per release.
- **Weekly compose bake (cron, Sun 04:00 UTC):** skips base, runs
  only repo + compose against the current moving `:<ubuntu>` base.
  Tags composed `:<branch>-YYYYMMDD` + moves `:<branch>`.
- **Monthly base refresh (cron, 1st of month 03:00 UTC):** refreshes
  base apt state (`:<ubuntu>-YYYY.MM.DD` + moving `:<ubuntu>`).
  Doesn't compose — next weekly cron picks up the refreshed base
  automatically.
- **Manual:** `workflow_dispatch` with independent `base` /
  `compose` toggles, branch dropdown, `push` toggle (default off =
  sanity build), optional `base_tag` override for compose.

All in one workflow:
[`.github/workflows/oea-buildsystem.yml`](../.github/workflows/oea-buildsystem.yml).

## See also

- [`oea-buildsystem-base`](./oea-buildsystem-base) — Dockerfile,
  entrypoint contract, full env-var + volume reference, Ubuntu-tag
  selection, `oea-retry` helper.
- [`oea-buildsystem-repo`](./oea-buildsystem-repo) — the tree-image
  side (checked-out `build-enviroment`).
- [`minio`](./minio) — companion object-store stack.
