# docker-images

Container images for WXbet-org, published to [ghcr.io/wxbet-org](https://github.com/orgs/WXbet-org/packages).

- **`dreamos-buildsystem-*`** — reproducible opendreambox build environment on Ubuntu 18.04 (this repo hosts the Dockerfiles and the release CI). See the quickstart below.
- **`simplebuild4`** — s4 build system (source lives in GitLab `common/simplebuild4`; this repo only hosts the Dockerfile and the release workflow, triggered from GitLab). See [simplebuild4 section](#simplebuild4) below.

## Quick start

### 1. Install Docker

On Debian / Ubuntu:

```sh
sudo apt update
sudo apt install -y docker.io docker-compose-v2
sudo systemctl enable --now docker
sudo usermod -aG docker $USER    # so `docker` works without sudo
newgrp docker                    # activate the group in the current shell
```

Two packages suffice for running these images: `docker.io` is the daemon and CLI, `docker-compose-v2` provides the modern `docker compose ...` subcommand (needed for the compose files under [`dreamos-buildsystem-ubnt18/`](dreamos-buildsystem-ubnt18/)). Everything sits in the standard Ubuntu repo — no third-party PPA required.

If you also want to *build* multi-arch container images on this host (not needed for consuming what's already on ghcr), add `docker-buildx` to the apt line.

If your distro is very old and the pull in step 2 fails, install Docker CE from Docker's official repo instead: <https://docs.docker.com/engine/install/>.

On Windows or macOS: install Docker Desktop and skip to step 2.

#### 1a. Recommended: log rotation

Docker's default JSON log driver never rotates or truncates container logs — a chatty long-running container will happily fill your disk over weeks/months. Set a sane cap once for all containers:

```sh
sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  }
}
EOF
sudo systemctl restart docker
```

Each container is now allowed 5 × 50 MB = 250 MB of history, older lines rotate out. Applies to every container going forward. Existing containers need a restart (`docker restart <name>`) to pick up the new driver.

#### 1b. Optional: Portainer for a web UI

If you'd rather manage the container (and any others) from a browser instead of the CLI, drop Portainer CE on the same host:

```sh
docker volume create portainer_data
docker run -d \
    --name portainer \
    --restart=unless-stopped \
    -p 9443:9443 \
    -p 8000:8000 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest
```

Then open `https://<host>:9443` and create the initial admin account. Port `9443` is the UI, port `8000` is for remote Edge-Agents — leave it out if you only manage this host locally. Portainer picks up the local Docker daemon via the socket mount and lets you deploy the two [compose files under `dreamos-buildsystem-ubnt18/`](dreamos-buildsystem-ubnt18/) as *Stacks* directly from this Git repo. See [Long-running deployment](#3c-long-running-deployment-composestack) below.

### 2. Pull the build image

Public image, no `docker login` needed:

```sh
docker pull ghcr.io/wxbet-org/dreamos-buildsystem-ubnt18:latest
```

Roughly 19 GB compressed download / ~20 GB on disk — the bulk is a baked-in OE downloads snapshot at `/opt/dl-mirror` (~19 GB alone) that bitbake uses as PREMIRROR, so most fetches during a build never touch the network. The actual Ubuntu + toolchain part is only ~1.2 GB.

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

#### 3c. Long-running deployment (compose/stack)

For a service-style deployment that survives host reboots, comes back after Docker restart, and is easy to redeploy from Git, two ready-made compose files ship under [`dreamos-buildsystem-ubnt18/`](dreamos-buildsystem-ubnt18/):

- **[`docker-compose.mount.yaml`](dreamos-buildsystem-ubnt18/docker-compose.mount.yaml)** — bind-mounts host `$HOME/dreamos-builds` (or a custom `BUILDS_DIR`) into `/home/builder`. Best when you want to edit `local-ext.conf` etc. directly from the host. Requires `HOME=<your-home>` as an env var whenever the compose is not launched from your interactive shell (e.g. from a UI or a daemon).
- **[`docker-compose.volume.yaml`](dreamos-buildsystem-ubnt18/docker-compose.volume.yaml)** — puts `/home/builder` on a Docker-managed named volume. Host-agnostic, no env vars needed, portable across hosts. Trade-off: no direct host-side browsing of the BuildEnv trees (only via `docker compose exec` or SSH).

CLI usage:

```sh
# Pick one:
docker compose -f dreamos-buildsystem-ubnt18/docker-compose.mount.yaml  up -d
docker compose -f dreamos-buildsystem-ubnt18/docker-compose.volume.yaml up -d

# Access
ssh -p 2222 builder@localhost                   # sshd is up as usual
docker compose -f <file> exec dreamos-buildsystem bash
```

Both files set `restart: unless-stopped`, so the container comes back automatically after Docker restarts. The first container start still runs the same [auto-bootstrap](#first-start-auto-bootstrap) as the plain `docker run` variant.

If you use Portainer (installed in [step 1b](#1b-optional-portainer-for-a-web-ui)), deploy either file as a **Stack → Repository**:

- Repository URL: `https://github.com/WXbet-org/docker-images`
- Repository reference: `refs/heads/master`
- Compose path: `dreamos-buildsystem-ubnt18/docker-compose.mount.yaml` (or `.volume.yaml`)
- Env vars: `HOME=/home/<youruser>` for the mount variant; leave empty for the volume variant

#### Flags explained

- `-v ~/dreamos-builds:/home/builder` bind-mounts a host folder as the `builder` user's home. Everything the builder does (BuildEnv checkouts, downloaded sources, GPG keyring, `.bash_history`, …) persists across container restarts.
- `-p 2222:22` publishes the container's sshd on host port 2222. Login from anywhere on the host with `ssh builder@localhost -p 2222` (password: `builder`).

#### First-start auto-bootstrap

On the **very first container start** with an empty `~/dreamos-builds`, the entrypoint auto-clones the four standard BuildEnv variants (`opendreambox/{krogoth,pyro}` and `dreamlegacy/{krogoth,pyro}`) into that folder. Takes several minutes. A marker file `~/dreamos-builds/.auto-bootstrap-done` prevents re-runs. Skip it entirely with `-e AUTO_BOOTSTRAP=0`.

### 4. Build

Each BuildEnv uses a Makefile as its top-level entry point. `make help` inside one of them lists every option; the common flow:

```sh
cd ~/opendreambox/krogoth   # or ~/opendreambox/pyro, ~/dreamlegacy/{krogoth,pyro}

# Build the firmware image (default target: dreambox-image)
MACHINE=dm900 make image
```

Make targets — full breakdown (verified against `opendreambox/pyro/Makefile`):

**Image builds** (run `do_rootfs`, produce a flashable firmware image):

- `MACHINE=… make image` — builds `$(MAKE_IMAGE_BB)`, default `dreambox-image`. Same as `make dreambox-image` unless you override, e.g. `MAKE_IMAGE_BB=my-custom-image make image`
- `MACHINE=… make dreambox-image` — explicit form of the default image build (identical to `make image` with defaults). Full firmware: kernel + rootfs + enigma2 GUI + apps + package feeds
- `MACHINE=… make console-image` — builds `dreambox-console-image`. Minimal image without GUI, useful for headless testing
- `MACHINE=… make rescue-image` — builds `dreambox-rescue-image-<MACHINE>` (per-machine variant). Recovery image for reflashing a bricked box

**Single-package builds** (no image, no `do_rootfs`, only `do_package_write_deb` for the named recipe and its dependencies):

- `MACHINE=… make enigma2` — builds just the `enigma2` package. Fast iteration when working on enigma2 alone; the resulting `.deb` lands in `build/<MACHINE>/tmp/deploy/deb/<PACKAGEARCH>/`. Any other recipe name works too — the target `dreambox-image enigma2 package-index: init` in the Makefile is a generic shortcut for `bitbake <recipe>`
- `MACHINE=… make package-index` — regenerate `Packages` / `Release` feed indexes for `tmp/deploy/deb/` (with signatures if signing is on). **Not** normally needed: `make image` already writes these as part of `do_rootfs` (via `oe.rootfs.DpkgRootfs._create → pm.write_index()`). Useful only when you've built individual packages with `make <pkg>` / `bitbake <pkg>` and want the feed refreshed without a full image rebuild — see [Hosting your own package feed](#hosting-your-own-package-feed)

**House-keeping:**

- `MACHINE=… make download` — pre-fetch of all sources for the target (shakes out network / mirror issues before the long build starts)
- `make update` — refresh the SDK (submodules) after upstream changes
- `make clean` / `make distclean` — remove generated config files (does *not* touch `build/`)
- `make sstate-cache-clean` — prune the shared-state cache (per-machine, keeps only live stamps)
- `make help` — authoritative on-screen reference plus your current settings

For manual bitbake invocation without going through make:

```sh
cd build/<MACHINE>
source bitbake.env
bitbake <recipe>   # e.g. enigma2, dreambox-image, package-index, ...
```

`make <name>` is just a shortcut for that — same result, less typing, and it takes care of the `MACHINE=…` prefix and the `bitbake.env` sourcing.

**Machine matrix** (which BuildEnv branch supports which target):

| | krogoth | pyro |
|---|:---:|:---:|
| `dm520`, `dm7080`, `dm820`, `dm900`, `dm920` | ✅ | — |
| `dreamone`, `dreamtwo` | — | ✅ |

Set `MACHINE` per-invocation via `MACHINE=… make …` or persist it inside a BuildEnv with `echo MACHINE=dm900 >> conf/make.conf`.

### Notes for constrained hosts (WSL2, small VMs, laptops)

opendreambox auto-detects `nproc` and sets `BB_NUMBER_THREADS` + `PARALLEL_MAKE` aggressively. Template-heavy recipes like `boost::log` and `qtwebkit` can allocate 1–2 GB of RAM per `cc1plus` — so a stock WSL2 instance (default 6-8 GB) OOM-kills the compiler mid-build:

```
arm-oe-linux-gnueabi-g++: internal compiler error: Killed (program cc1plus)
```

Fix in the affected BuildEnv's `conf/local-ext.conf` — the [`bootstrap-buildenv`](dreamos-buildsystem-base/bootstrap-buildenv.sh) template ships pre-commented lines for this, uncomment to activate:

```sh
# ~8 GB host (typical WSL2):
BB_NUMBER_THREADS = "3"
PARALLEL_MAKE     = "-j 4"

# On a bigger host (~16 GB) that only chokes on the known hogs, the
# targeted per-recipe caps alone are usually enough:
PARALLEL_MAKE_pn-boost           = "-j 4"
PARALLEL_MAKE_pn-boost-native    = "-j 4"
PARALLEL_MAKE_pn-qtwebkit        = "-j 4"
PARALLEL_MAKE_pn-qtwebkit-native = "-j 4"
```

Alternatively give WSL2 more RAM/swap once in `%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
memory=16GB
swap=8GB
```

Then `wsl --shutdown` and restart. With ≥16 GB you can leave the auto-detected caps alone.

### Package feed URL — release channel and distro version

The feed URL that ends up on the receiver's `/etc/apt/sources.list.d/*.list` (dreambox is Debian-based → apt/dpkg, not opkg) is composed at build time from:

```sh
DISTRO_FEED_URI = "https://<host>/opendreambox/<distro-version>/<channel>/${PR}/${MACHINE}"
```

Two parameters are exposed in `conf/local-ext.conf`:

- **`DISTRO_FEED_CHANNEL`** — free-form path segment. `bootstrap-buildenv` writes it as `"unstable"` (sensible default for day-to-day work). Flip to `"stable"` when you're cutting a release build:
    ```sh
    DISTRO_FEED_CHANNEL = "stable"
    ```
- **`<distro-version>`** — coupled to the OE release branch. `bootstrap-buildenv` substitutes it at write time (`krogoth → 2.5`, `pyro → 2.6`), so a fresh `local-ext.conf` already has the correct value. If you need to change it later, edit the URL directly.

Bitbake variables `${PR}` and `${MACHINE}` are expanded by bitbake at package-build time — leave them literal in the config file.

To point the receiver at your own feed, replace the host in the URL and follow **Hosting your own package feed** below.

### Package feed signing

Signing is **enabled by default on the `opendreambox` fork** (which carries the "sign DEB package feeds" patch on `openembedded-core`) and **disabled by default on `dreamlegacy`** (whose `DpkgIndexer` ignores the flag — enabling would be a silent no-op). No manual switch-over needed either way; `bootstrap-buildenv` reads the fork and does the right thing when it writes `conf/local-ext.conf`.

The signing key itself is auto-generated on the *first container start* by `entrypoint.sh` (via `ensure-gpg-key`) if no keyring exists in `~/.gnupg/` yet: 4096-bit RSA, no expiry, identity `dreamos-buildsystem <builder@dreamos-buildsystem.local>`, random 32-char passphrase written to `~/.gnupg/passphrase` (mode 0600). Everything lives on the host bind-mount, so keys persist across container restarts and are shared across all BuildEnvs on that host. The generated fingerprint is then substituted into `conf/local-ext.conf` when `bootstrap-buildenv` runs for a BuildEnv.

The block that lands in `conf/local-ext.conf` (uncommented on opendreambox, commented on dreamlegacy):

```sh
PACKAGE_FEED_SIGN = '1'
PACKAGE_CLASSES = "package_deb sign_package_feed"
PACKAGE_FEED_GPG_BACKEND = 'local'
PACKAGE_FEED_GPG_SIGNATURE_TYPE = 'BIN'
PACKAGE_FEED_GPG_NAME = "<auto-filled fingerprint>"
PACKAGE_FEED_GPG_PASSPHRASE_FILE = "/home/builder/.gnupg/passphrase"
```

Caveats:

- On dreamlegacy the block is commented out because vanilla dreamlegacy (both `obi/krogoth` and `obi/pyro`) never reads `PACKAGE_FEED_SIGN` / `PACKAGE_FEED_GPG_*` in `DpkgIndexer` — you'd get unsigned `.deb` feeds either way, no error. **IPK** feeds (via `OpkgIndexer`) do sign on both branches, so if you switch `PACKAGE_CLASSES` to `package_ipk` you can uncomment the block by hand.
- Re-running `bootstrap-buildenv` reuses an existing keyring — no rotation, no fingerprint change in `local-ext.conf`.
- To disable signing on opendreambox: comment the six lines out again in that BuildEnv's `conf/local-ext.conf`.
- To use your own key instead of the auto-generated one: drop your `.gnupg/` into `~/dreamos-builds/.gnupg/` on the host *before* the container's first start, and auto-generation is skipped. Make sure `~/.gnupg/passphrase` (mode 0600, plain text) matches.

#### Managing signing keys

All GPG commands run inside the container against `~/.gnupg/` (which is your host `~/dreamos-builds/.gnupg/` bind-mounted in). Anything you do here persists.

**List keys** — what's there and which fingerprint to reference in `local-ext.conf`:

```sh
gpg --list-secret-keys --keyid-format=long
# Long fingerprint only (the format PACKAGE_FEED_GPG_NAME expects):
gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10}'
```

**Generate a new key manually** — batch mode, no interactive prompts:

```sh
PASS='choose-a-passphrase'
gpg --batch --pinentry-mode loopback --generate-key <<EOF
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: my-signing-key
Name-Email: builder@example.local
Expire-Date: 0
Passphrase: $PASS
%commit
EOF
echo "$PASS" > ~/.gnupg/passphrase && chmod 600 ~/.gnupg/passphrase
```

Then paste the new fingerprint (from `--list-secret-keys` above) into `PACKAGE_FEED_GPG_NAME` in every BuildEnv's `conf/local-ext.conf`.

**Import an existing key** (e.g. copied from another build server):

```sh
gpg --import /path/to/private.asc     # secret key
gpg --import /path/to/public.asc      # public key (of a co-signer)
# Give the imported key ultimate trust so signing doesn't warn:
FPR=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')
echo "$FPR:6:" | gpg --import-ownertrust
```

**Export the public key** — needed on the receiver side (STB, apt-key on a test client) to verify signed feeds:

```sh
gpg --armor --export builder@dreamos-buildsystem.local > dreamos-feed-pubkey.asc
# → deploy to the client and: apt-key add dreamos-feed-pubkey.asc
```

**Rotate / remove a key**:

```sh
gpg --delete-secret-keys <FINGERPRINT>   # deletes secret half first
gpg --delete-keys        <FINGERPRINT>   # then the public half
```

After rotation don't forget to update `PACKAGE_FEED_GPG_NAME` in each BuildEnv's `conf/local-ext.conf` and re-distribute the new public key to feed consumers.

### Hosting your own package feed

After `MACHINE=xxx make image`, all package artefacts land locally in the BuildEnv:

```
build/<MACHINE>/tmp/deploy/deb/          <- one subdir per PACKAGEARCH
                          ├── all/
                          ├── <MACHINE>/
                          ├── cortexa15hf-neon-vfpv4/
                          └── ...
```

A "feed" is nothing more than that directory tree served over HTTP(S) plus generated index files (`Packages`, `Packages.gz`, `Release`) per architecture directory. The receiver's `apt` fetches those indexes from `${DISTRO_FEED_URI}` and installs `.deb` files listed in them (dreambox is Debian-based → apt/dpkg on the receiver, not opkg).

Minimal setup:

1. **Feed indexes** (`Packages` / `Packages.gz` / `Release` + `Release.gpg` when signing is on) are written **automatically** as part of `make image`. Specifically, `do_rootfs` in [`oe/rootfs.py:650`](https://git.openembedded.org/openembedded-core/tree/meta/lib/oe/rootfs.py?h=pyro) calls `pm.write_index()` on the DEB package manager, which invokes the `DpkgIndexer` — the same code path that `bitbake package-index` runs — over the entire `tmp/deploy/deb/` tree. So after `make image`, the feed is already index-ready on disk.

    You only need `MACHINE=<machine> make package-index` explicitly when you built individual packages with `bitbake <pkg>` (no `do_rootfs` → no auto-refresh) and want the indexes updated without a full image rebuild.
2. **Publish** the entire `tmp/deploy/deb/` tree over HTTP — nginx / apache / caddy / any static file server does the job. Match the URL layout to `DISTRO_FEED_URI`, so `<host>/opendreambox/2.6/unstable/<PR>/<MACHINE>/` resolves to the corresponding `deploy/deb/<PACKAGEARCH>/` directory (a bit of `rewrite` / symlink glue is usually needed — every host layouts this differently).
3. **Point `DISTRO_FEED_URI`** at your host, rebuild the image, install → the receiver's `/etc/apt/sources.list.d/*.list` now references your URL.
4. **If signing is enabled**: distribute the public key (`gpg --armor --export > pubkey.asc`) to receivers. On the STB: `apt-key add pubkey.asc` (or bake the key into the image via a custom recipe by dropping the armored key into `/etc/apt/trusted.gpg.d/`).

Common workflow after each image build:

```sh
MACHINE=dm900 make image
# Feed indexes are already written under build/dm900/tmp/deploy/deb/
rsync -a build/dm900/tmp/deploy/deb/ user@feedhost:/var/www/opendreambox/2.6/unstable/
```

Deeper background from the Yocto Project reference manual (same mechanism, all OE-based distros): <https://docs.yoctoproject.org/dev-manual/packages.html#creating-and-using-a-package-feed>.

Deep-dive documentation (Dockerfile internals, PREMIRRORS setup, the two-image split): [`dreamos-buildsystem-ubnt18/README.md`](dreamos-buildsystem-ubnt18/README.md).

## Architecture — three images, composed on the registry

To keep CI fast without dragging the 11 GB sources snapshot into every rebuild, the consumable `dreamos-buildsystem-ubnt18` image is composed at the OCI manifest level from two smaller source images. No consumer needs to know this — a single `docker pull ubnt18:latest` still gets everything.

```
dreamos-buildsystem-base            dreamos-buildsystem-sources
   (ubuntu + toolchain,             (ubuntu + /opt/dl-mirror,
    ~1.2 GB, CI-built)               ~19 GB, built manually on build server)
             \                              /
              \                            /
               \_________ regctl _________/
                        composes on ghcr
                        (server-side layer mount,
                         no blob download to runner)
                              │
                              ▼
              dreamos-buildsystem-ubnt18
              (~20 GB, what consumers pull)
```

**Why this split:**

- **base** — rebuilds on every code/toolchain/ESM-patch change. Small (~1.2 GB), fast CI (~5 min). The next base release only re-pushes this small layer to ghcr; the huge sources layer stays untouched.
- **sources** — rebuilds only when the OE downloads snapshot needs refreshing (rare, manual on the build server). Docker layer is ~19 GB even though the raw `sources-seed/` folder on the host is only ~11 GB — the layer includes tar metadata for the ~1200 individual files + git-mirror objects.
- **ubnt18** — composed on ghcr from base + sources via `regctl` and OCI cross-repo blob mount. **No layer blobs are downloaded during composition** — the ubnt18 manifest is crafted from the existing base+sources manifests and pushed. Runtime: ~30 seconds on a stock GHA runner.

**Consumer download cost after a fresh base release:** the sources layer is unchanged → already-cached by Docker → only ~1.2 GB of new toolchain layer is pulled. First-time pull of the full image is ~19 GB compressed.

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
├── simplebuild4/                      s4 build artefacts (source stays in GitLab)
│   ├── Dockerfile                     FROM ubuntu:26.04 + s4 runtime + apt/pip
│   ├── .dockerignore                  build-context filter
│   └── docker-compose.yaml            one-liner user deployment
└── .github/workflows/
    ├── dreamos-buildsystem-ubnt18.yml Builds base + composes ubnt18 on tag push;
    │                                  workflow_dispatch = base-only sanity check (no push)
    ├── simplebuild4.yml               Builds s4 on repository_dispatch from GitLab
    └── cleanup-ghcr.yml               Weekly prune of orphaned untagged versions
```

## Images

| Image | Purpose | How it's built |
|-------|---------|----------------|
| [`dreamos-buildsystem-base`](dreamos-buildsystem-base/README.md) | Toolchain only (~2 GB) | CI as phase 1 of a `dreamos-buildsystem-ubnt18/vX.Y.Z` tag push |
| [`dreamos-buildsystem-sources`](dreamos-buildsystem-sources/README.md) | ~11 GB OE sources snapshot at `/opt/dl-mirror` | Manually on the build server (`./build.sh` in that folder) |
| [`dreamos-buildsystem-ubnt18`](dreamos-buildsystem-ubnt18/README.md) | Composed (~13 GB) — consumer-facing | CI on `dreamos-buildsystem-ubnt18/vX.Y.Z` tag push (composes base + sources on ghcr) |
| [`simplebuild4`](simplebuild4/) | s4 cross-compilation build system (~1.5 GB) | CI on `repository_dispatch` from GitLab tag push (see [simplebuild4](#simplebuild4)) |

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

If you're tweaking the Dockerfile and just want to verify the base still builds, trigger the `dreamos-buildsystem-ubnt18` workflow via **workflow_dispatch** from the Actions tab. Phase 1 runs with `push: false` — the image is built to prove Dockerfile / apt / pip / ESM-attach still work, but no bytes land on GHCR. Phase 2 (ubnt18 composition) is skipped.

### `:latest` promotion

Both base and ubnt18 `:latest` are updated only when the pushed version is the highest sortable `dreamos-buildsystem-ubnt18/*` tag (`git tag -l ... | sort -V | tail -1`). Guards against a late hotfix on an older branch accidentally overwriting `:latest`.

## simplebuild4

The [s4 build system](https://git.streamboard.tv/common/simplebuild4) is published as `ghcr.io/wxbet-org/simplebuild4`. The **source lives in GitLab**; this repo only holds the packaging (Dockerfile + .dockerignore + docker-compose.yaml) and the release workflow.

### User deployment

Full docs (interactive TUI mode, headless web+mcp, data persistence, updates): [s4 wiki → Docker](https://git.streamboard.tv/common/simplebuild4/-/wikis/getting-started/docker).

### Trigger flow

1. Someone pushes a git tag (e.g. `1.2.3`) to the GitLab s4 repo.
2. The GitLab CI job in that repo POSTs a `repository_dispatch` to this repo (event type `simplebuild4-release`, payload `{ tag, sha }`).
3. [`.github/workflows/simplebuild4.yml`](.github/workflows/simplebuild4.yml) runs, clones s4 at that SHA, overlays this repo's Dockerfile into the clone, and builds + pushes `ghcr.io/wxbet-org/simplebuild4:<tag>` (and `:latest` if this tag is the highest sortable one in s4).

For a manual run — e.g. to rebuild an existing tag or build HEAD of the default branch — trigger the workflow via `workflow_dispatch` from the Actions tab (optional `tag` input).
