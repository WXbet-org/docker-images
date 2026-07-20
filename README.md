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

```sh
mkdir -p ~/dreamos-builds

docker run --rm -it \
    -p 2222:22 \
    -v ~/dreamos-builds:/home/builder \
    ghcr.io/wxbet-org/dreamos-buildsystem-ubnt18:latest
```

- `-v ~/dreamos-builds:/home/builder` mounts a host folder as the builder user's home so BuildEnv checkouts and downloaded sources persist across container runs
- `-p 2222:22` publishes the container's sshd; log in with `ssh builder@localhost -p 2222` (password: `builder`)

On the **very first container start** with an empty `~/dreamos-builds`, the entrypoint auto-clones the four standard BuildEnv variants (`opendreambox/{krogoth,pyro}` and `dreamlegacy/{krogoth,pyro}`) into that folder. Takes several minutes. A marker file `~/dreamos-builds/.auto-bootstrap-done` prevents re-runs. Skip it entirely with `-e AUTO_BOOTSTRAP=0`.

Inside the container, run a build the standard opendreambox way:

```sh
cd ~/opendreambox/krogoth
MACHINE=dm900 make init
MACHINE=dm900 make download
# ...then bitbake your target image
```

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
