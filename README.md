# docker-images

Container images for WXbet-org, published to [ghcr.io/wxbet-org](https://github.com/orgs/WXbet-org/packages). Provides a reproducible opendreambox build environment on Ubuntu 18.04.

## Quick start

### 1. Install Docker

On Debian / Ubuntu:

```sh
sudo apt update
sudo apt install -y docker.io
sudo usermod -aG docker $USER    # so `docker` works without sudo
newgrp docker                    # activate the group in the current shell
```

The distribution's `docker.io` package is enough for **running** these images (Docker 18.09+ pulls and runs OCI-compliant manifests). If your distro is very old and the pull fails, install Docker CE from Docker's official repo: <https://docs.docker.com/engine/install/>.

On Windows or macOS: install Docker Desktop and skip to step 2.

### 2. Pull the build image

Public image, no `docker login` needed:

```sh
docker pull ghcr.io/wxbet-org/dreamos-buildsystem-ubnt18:latest
```

Roughly 13 GB on disk — the bulk is a baked-in OE downloads snapshot at `/opt/dl-mirror` that bitbake uses as PREMIRROR, so most fetches during a build never touch the network.

### 3. Start it

Two patterns depending on how long-lived your session is.

#### 3a. Quick interactive session (`--rm -it`)

Good for a first look or a short test. The container is torn down on exit.

```sh
mkdir -p ~/dreamos-builds

docker run --rm -it \
    -p 2222:22 \
    -v ~/dreamos-builds:/home/builder \
    ghcr.io/wxbet-org/dreamos-buildsystem-ubnt18:latest
```

You land directly in a bash prompt as the `builder` user.

#### 3b. Long-running container (recommended for real builds)

Detach the container so bitbake keeps running when you close the terminal, and attach a shell whenever you need one:

```sh
mkdir -p ~/dreamos-builds

# Start detached and named -- `sleep infinity` keeps it alive since
# bash without a TTY would exit immediately in detached mode
docker run -d --name dreamos-builder \
    -p 2222:22 \
    -v ~/dreamos-builds:/home/builder \
    ghcr.io/wxbet-org/dreamos-buildsystem-ubnt18:latest \
    sleep infinity

# Open a shell inside it
docker exec -it dreamos-builder bash

# Open a second shell in another terminal (as many as you want)
docker exec -it dreamos-builder bash

# When done -- stop and remove
docker stop dreamos-builder && docker rm dreamos-builder
```

`docker exec` shells survive Ctrl+D — the container keeps running until you `docker stop` it.

#### Flags explained

- `-v ~/dreamos-builds:/home/builder` bind-mounts a host folder as the `builder` user's home. Everything the builder does (BuildEnv checkouts, downloaded sources, GPG keyring, `.bash_history`, …) persists across container restarts.
- `-p 2222:22` publishes the container's sshd on host port 2222. Login from anywhere on the host with `ssh builder@localhost -p 2222` (password: `builder`).

#### First-start auto-bootstrap

On the **very first container start** with an empty `~/dreamos-builds`, the entrypoint auto-clones the four standard BuildEnv variants (`opendreambox/{krogoth,pyro}` and `dreamlegacy/{krogoth,pyro}`) into that folder. Takes several minutes. A marker file `~/dreamos-builds/.auto-bootstrap-done` prevents re-runs. Skip it entirely with `-e AUTO_BOOTSTRAP=0`.

### 4. Build

Each BuildEnv uses a Makefile as its top-level entry point. `make help` inside one of them lists every option; the common flow:

```sh
cd ~/opendreambox/krogoth   # or ~/opendreambox/pyro, ~/dreamlegacy/{krogoth,pyro}

# Optional pre-fetch of all sources for the target -- shakes out
# network / mirror issues before the long build starts
MACHINE=dm900 make download

# Build the firmware image (default target: dreambox-image)
MACHINE=dm900 make image
```

Other useful Make targets:

- `make image MACHINE=…` — full firmware image
- `make console-image MACHINE=…` — minimal console-only variant
- `make rescue-image MACHINE=…` — recovery image
- `make update` — refresh the SDK (submodules) after upstream changes
- `make help` — the authoritative list, plus your current settings

For manual bitbake invocation of a single recipe:

```sh
cd build/dm900
source bitbake.env
bitbake enigma2   # or any other recipe
```

**Machine matrix** (which BuildEnv branch supports which target):

| | krogoth | pyro |
|---|:---:|:---:|
| `dm520`, `dm7080`, `dm820`, `dm900`, `dm920` | ✅ | — |
| `dreamone`, `dreamtwo` | — | ✅ |

Set `MACHINE` per-invocation via `MACHINE=… make …` or persist it inside a BuildEnv with `echo MACHINE=dm900 >> conf/make.conf`.

Deep-dive documentation (Dockerfile internals, PREMIRRORS setup, GPG package signing, the two-image split): [`dreamos-buildsystem-ubnt18/README.md`](dreamos-buildsystem-ubnt18/README.md).

## Architecture — three images, composed on the registry

To keep CI fast without dragging the 11 GB sources snapshot into every rebuild, the consumable `dreamos-buildsystem-ubnt18` image is composed at the OCI manifest level from two smaller source images. No consumer needs to know this — a single `docker pull ubnt18:latest` still gets everything.

```
dreamos-buildsystem-base            dreamos-buildsystem-sources
   (ubuntu + toolchain,             (ubuntu + /opt/dl-mirror,
    ~2 GB, CI-built)                 ~11 GB, built manually on build server)
             \                              /
              \                            /
               \_________ regctl _________/
                        composes on ghcr
                        (server-side layer mount,
                         no blob download to runner)
                              │
                              ▼
              dreamos-buildsystem-ubnt18
              (~13 GB, what consumers pull)
```

**Why this split:**

- **base** — rebuilds on every code/toolchain/ESM-patch change. Small, fast CI (~5 min).
- **sources** — rebuilds only when the OE downloads snapshot needs refreshing (rare, manual on the build server).
- **ubnt18** — composed on ghcr from base + sources via `regctl` and OCI cross-repo blob mount. **No layer blobs are downloaded during composition** — the ubnt18 manifest is crafted from the existing base+sources manifests and pushed. Runtime: ~30 seconds on a stock GHA runner.

## Layout

```
.
├── dreamos-buildsystem-base/          Toolchain-only image (~2 GB, CI-built)
│   ├── Dockerfile                     FROM ubuntu:18.04 + apt install / pro attach / entrypoint
│   ├── build.sh
│   ├── entrypoint.sh
│   ├── bootstrap-buildenv.sh
│   ├── pro-attach-config.yaml.example
│   └── README.md
├── dreamos-buildsystem-sources/       Data image (~11 GB, built manually)
│   ├── Dockerfile                     FROM ubuntu:18.04 + COPY sources-seed /opt/dl-mirror
│   ├── build.sh
│   └── README.md
├── dreamos-buildsystem-ubnt18/        Composed consumable -- no Dockerfile!
│   ├── compose.sh                     regctl-based manifest composition
│   ├── run.sh                         consumer helper
│   └── README.md
└── .github/workflows/
    ├── dreamos-buildsystem-base.yml   Builds base on tag push
    └── dreamos-buildsystem-ubnt18.yml Composes ubnt18 on tag push
```

## Images

| Image | Purpose | How it's built |
|-------|---------|----------------|
| [`dreamos-buildsystem-base`](dreamos-buildsystem-base/README.md) | Toolchain only (~2 GB) | CI on `dreamos-buildsystem-base/vX.Y.Z` tag push |
| [`dreamos-buildsystem-sources`](dreamos-buildsystem-sources/README.md) | ~11 GB OE sources snapshot at `/opt/dl-mirror` | Manually on the build server (`./build.sh` in that folder) |
| [`dreamos-buildsystem-ubnt18`](dreamos-buildsystem-ubnt18/README.md) | Composed (~13 GB) — consumer-facing | CI on `dreamos-buildsystem-ubnt18/vX.Y.Z` tag push (composes base + sources on ghcr) |

## Release

**One tag does the whole release.** Push `dreamos-buildsystem-ubnt18/vX.Y.Z` and the workflow:

1. Builds the base image with fresh apt/ESM patches (`--no-cache`), pushes it as `dreamos-buildsystem-base:vX.Y.Z` + `:latest`
2. Composes the ubnt18 image on ghcr from the just-built base + the current `dreamos-buildsystem-sources:latest`, pushes as `dreamos-buildsystem-ubnt18:vX.Y.Z` + `:latest`

```sh
git tag dreamos-buildsystem-ubnt18/v0.3.0
git push origin dreamos-buildsystem-ubnt18/v0.3.0
```

Total time: ~5 min for phase 1 (apt install), ~30 sec for phase 2 (regctl compose).

Base and ubnt18 always share the same version number by design — every ubnt18 release is a matched pair with its base.

The sources image has its own release cadence and is built + tagged manually on the build server. Refreshing sources requires a subsequent ubnt18 release to compose it in.

### For base-only iteration

If you're tweaking the Dockerfile and just want to test a base build without cutting a release, trigger the `dreamos-buildsystem-base` workflow via **workflow_dispatch** from the Actions tab. It pushes `dreamos-buildsystem-base:latest` only, no ubnt18 composition.

### `:latest` promotion

Both base and ubnt18 `:latest` are updated only when the pushed version is the highest sortable `dreamos-buildsystem-ubnt18/*` tag (`git tag -l ... | sort -V | tail -1`). Guards against a late hotfix on an older branch accidentally overwriting `:latest`.
