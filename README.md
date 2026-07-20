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

## Layout

One folder per image with its Dockerfile, build scripts, and README. One GitHub Actions workflow per image, triggered by git tags prefixed with the image name.

```
.
├── dreamos-buildsystem-sources/      Data image: ~11 GB OE downloads snapshot at /opt/dl-mirror
│   ├── Dockerfile
│   ├── build.sh
│   └── README.md
├── dreamos-buildsystem-ubnt18/       Ubuntu 18.04 + Pro/ESM toolchain -- FROM dreamos-buildsystem-sources
│   ├── Dockerfile
│   ├── build.sh / run.sh
│   ├── bootstrap-buildenv.sh
│   ├── entrypoint.sh
│   ├── pro-attach-config.yaml.example
│   └── README.md
└── .github/workflows/
    └── dreamos-buildsystem-ubnt18.yml
```

## Images

| Image | Purpose | Details |
|-------|---------|---------|
| [`dreamos-buildsystem-sources`](dreamos-buildsystem-sources/README.md) | Data-only image with the ~11 GB OE sources snapshot at `/opt/dl-mirror`. Serves as base for the toolchain image so the layer is deduped in the registry. | [README](dreamos-buildsystem-sources/README.md) |
| [`dreamos-buildsystem-ubnt18`](dreamos-buildsystem-ubnt18/README.md) | Ubuntu 18.04 + gcc-6.5 + Python 2.7/3.6 for opendreambox. Extends the sources image with the build toolchain. | [README](dreamos-buildsystem-ubnt18/README.md) |

## Release convention

Git tags are prefixed with the image name so each image can be versioned and released independently:

```
<image-name>/<version>

Examples:
  dreamos-buildsystem-ubnt18/v0.1.0
  dreamos-buildsystem-ubnt18/v1.2.3-rc1
```

Pushing such a tag triggers exactly the matching workflow and publishes to `ghcr.io/wxbet-org/<image-name>:<version>` (and `:latest` if the version is the highest sortable one for that image).

## Adding a new image

1. Create a new `<image-name>/` folder with a `Dockerfile` and `README.md`.
2. Add a new workflow `.github/workflows/<image-name>.yml` based on [`dreamos-buildsystem-ubnt18.yml`](.github/workflows/dreamos-buildsystem-ubnt18.yml) — mainly adjust `IMAGE`, `IMAGE_DIR`, `TAG_PREFIX`, and the trigger.
3. On first push, set the package visibility under WXbet-org to public if desired.
