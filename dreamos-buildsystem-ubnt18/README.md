# dreamos-buildsystem-ubnt18

Consumable opendreambox / dreamlegacy build image — Ubuntu 18.04 +
Pro/ESM + full OE toolchain + ~11 GB baked-in `/opt/dl-mirror`
sources snapshot. Supports krogoth (`dm520`, `dm7080`, `dm820`,
`dm900`, `dm920`) and pyro (`dreamone`, `dreamtwo`).

## Quick start

### 1. Pull the image

Public, no `docker login` needed:

```sh
docker pull ghcr.io/wxbet-org/dreamos-buildsystem-ubnt18:latest
```

~19 GB compressed / ~20 GB on disk — most of it is the baked-in OE
downloads snapshot at `/opt/dl-mirror` (~19 GB) that bitbake uses as
PREMIRROR, so builds barely touch the network. The Ubuntu +
toolchain part is only ~1.2 GB.

### 2. Start it

Two patterns depending on how long-lived your session is.

> ⚠️ **UID matters for bind mounts.** The container runs as user
> `builder` (uid 1000). Bind-mount targets on the host must be owned
> by uid 1000, or bitbake hits `Permission denied` immediately. Two
> fixes:
>
> - Mount from a host directory owned by uid 1000 (typical for the
>   primary Linux desktop user — `id -u` returns 1000).
> - Or align ownership: `sudo chown -R 1000:1000 <path>`.
>
> Or use the named-volume compose variants — Docker manages
> permissions inside a named volume automatically.

#### 2a. Quick interactive session

```sh
mkdir -p ~/dreamos-builds

docker run --rm -it \
    -p 2222:22 \
    -v ~/dreamos-builds:/home/builder \
    ghcr.io/wxbet-org/dreamos-buildsystem-ubnt18:latest
```

Bash prompt as `builder`. Container torn down on exit.

#### 2b. Long-running container

Detach so bitbake keeps running when you close the terminal:

```sh
mkdir -p ~/dreamos-builds

docker run -d --name dreamos-builder \
    -p 2222:22 \
    -v ~/dreamos-builds:/home/builder \
    ghcr.io/wxbet-org/dreamos-buildsystem-ubnt18:latest \
    sleep infinity

# Attach one or many shells
docker exec -it dreamos-builder bash

# Tear down when done
docker stop dreamos-builder && docker rm dreamos-builder
```

`docker exec` shells survive Ctrl+D — container keeps running.

#### 2c. Long-running compose stack

For service-style deployment (survives host reboots, redeploy from
Git via your orchestrator's web UI), two ready-made compose files
ship in this directory:

- [`docker-compose.mount.yaml`](docker-compose.mount.yaml) — bind-mounts
  host `$HOME/dreamos-builds` (or `BUILDS_DIR`) to `/home/builder`.
  Best when you want to edit `local-ext.conf` from the host. Requires
  `HOME=<your-home>` env-var when launched non-interactively.
- [`docker-compose.volume.yaml`](docker-compose.volume.yaml) — puts
  `/home/builder` on named volume `dreamos_build_data`. Host-agnostic,
  no env vars needed.

```sh
docker compose -f docker-compose.volume.yaml up -d
ssh -p 2222 builder@localhost                   # password: builder
docker compose -f docker-compose.volume.yaml exec dreamos-buildsystem bash
```

Both `restart: unless-stopped`. First start runs the auto-bootstrap
(see below).

#### 2d. One-shot batch build (CI-style)

For "run to completion, capture exit code" workloads (CI, mass
builds, orchestrator flows):

- [`docker-compose.build.mount.yaml`](docker-compose.build.mount.yaml) — bind-mount variant.
- [`docker-compose.build.volume.yaml`](docker-compose.build.volume.yaml) — named-volume variant (shares `dreamos_build_data` with the long-running variant, so warm cache carries over).

Key behavior:

- `make image` runs as PID 1 → bitbake output goes to `docker logs`
- `restart: "no"` → container exits when build is done; exit code = build result
- `AUTO_BOOTSTRAP=0` + explicit `bootstrap-buildenv` for just the one BuildEnv → saves ~15 min vs bootstrapping all four
- Per-MACHINE failures don't abort the batch — loop collects failures, returns non-zero at end with a summary + log paths
- Runs as `builder` (uid 1000)
- SSH published on `${SSH_PORT:-2222}` for peeking at a running build

Env vars:

| Var | Default | Meaning |
|---|---|---|
| `TAG` | `latest` | Image version pin |
| `FORK` | `opendreambox` | `opendreambox` or `dreamlegacy` |
| `BRANCH` | `krogoth` | any branch of the fork |
| `MACHINES` | `dm900` | space-separated list, e.g. `"dm520 dm820 dm7080 dm900 dm920"` |
| `SSH_PORT` | `2222` | host port for optional SSH peek |
| `HOME` / `BUILDS_DIR` | `$HOME/dreamos-builds` | mount variant only |

```sh
docker compose -f docker-compose.build.volume.yaml up
MACHINES="dm520 dm820 dm7080 dm900 dm920" docker compose -f docker-compose.build.volume.yaml up
docker compose -f docker-compose.build.volume.yaml up -d
docker compose -f docker-compose.build.volume.yaml logs -f
```

Container name for the batch variant is `dreamos-build-auto` (fixed);
long-running is `dreamos-buildsystem`. Both use the SAME
`dreamos_build_data` volume for warm-cache sharing.

#### First-start auto-bootstrap

On the **very first** container start with empty `~/dreamos-builds`,
the entrypoint auto-clones the four standard BuildEnv variants
(`opendreambox/{krogoth,pyro}` and `dreamlegacy/{krogoth,pyro}`).
Takes several minutes. Marker file
`~/dreamos-builds/.auto-bootstrap-done` prevents re-runs. Skip with
`-e AUTO_BOOTSTRAP=0`.

### 3. Build

Each BuildEnv uses a Makefile as its top-level entry point. `make
help` lists everything; the common flow:

```sh
cd ~/opendreambox/krogoth   # or ~/opendreambox/pyro, ~/dreamlegacy/{krogoth,pyro}

MACHINE=dm900 make image    # default target: dreambox-image
```

**Machine matrix:**

| | krogoth | pyro |
|---|:---:|:---:|
| `dm520`, `dm7080`, `dm820`, `dm900`, `dm920` | ✅ | — |
| `dreamone`, `dreamtwo` | — | ✅ |

**Make targets** (verified against `opendreambox/pyro/Makefile`):

*Image builds* (`do_rootfs` + full firmware):
- `MACHINE=… make image` — `$(MAKE_IMAGE_BB)`, default `dreambox-image`
- `MACHINE=… make dreambox-image` — explicit form, full firmware (kernel + rootfs + enigma2 + apps + feeds)
- `MACHINE=… make console-image` — minimal, no GUI
- `MACHINE=… make rescue-image` — per-machine recovery image

*Single-package builds* (only `do_package_write_deb` for the recipe + deps):
- `MACHINE=… make enigma2` — builds just the `enigma2` package. Any recipe name works — the target `dreambox-image enigma2 package-index: init` is a generic shortcut for `bitbake <recipe>`.
- `MACHINE=… make package-index` — regenerate feed indexes. Not normally needed (`make image` writes them via `do_rootfs → pm.write_index() → DpkgIndexer`). Only when you `bitbake <pkg>` individually.

*House-keeping:*
- `MACHINE=… make download` — pre-fetch sources
- `make update` — refresh SDK submodules
- `make clean` / `make distclean` — remove generated config
- `make sstate-cache-clean` — prune sstate

For manual bitbake:

```sh
cd build/<MACHINE>
source bitbake.env
bitbake <recipe>
```

`make <name>` is just a shortcut for that.

### 4. Notes for constrained hosts (WSL2, small VMs)

opendreambox auto-sets `BB_NUMBER_THREADS` + `PARALLEL_MAKE` from
`nproc`. Template-heavy recipes (`boost::log`, `qtwebkit`) allocate
1-2 GB per `cc1plus` — 6-8 GB WSL2 hits `internal compiler error:
Killed`. Fix in the BuildEnv's `conf/local-ext.conf`
(pre-commented in the template):

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

Alternatively raise WSL2 memory in `%USERPROFILE%\.wslconfig`:
`memory=16GB` + `swap=8GB`, then `wsl --shutdown`.

## Package feeds

### Feed URL — release channel + distro version

The URL that ends up on the receiver's `/etc/apt/sources.list.d/*.list`
(dreambox is Debian-based → apt/dpkg, not opkg) is composed at build
time:

```
DISTRO_FEED_URI = "https://<host>/opendreambox/<distro-version>/<channel>/${PR}/${MACHINE}"
```

Two parameters in `conf/local-ext.conf`:

- **`DISTRO_FEED_CHANNEL`** — free-form segment. `bootstrap-buildenv`
  writes `"unstable"` (default). Flip to `"stable"` for release builds.
- **`<distro-version>`** — coupled to the OE branch (`krogoth → 2.5`,
  `pyro → 2.6`). `bootstrap-buildenv` substitutes at write time.

`${PR}` and `${MACHINE}` are expanded by bitbake at package-build time
— leave literal in the config file.

### Signing

**Enabled by default on `opendreambox`** (carries the "sign DEB
package feeds" patch on openembedded-core), **disabled by default on
`dreamlegacy`** (`DpkgIndexer` ignores the flag — no-op either way).
`bootstrap-buildenv` reads the fork and does the right thing.

The signing key auto-generates on the first container start via
`entrypoint.sh → ensure-gpg-key` if no keyring exists in `~/.gnupg/`:
4096-bit RSA, no expiry, identity `dreamos-buildsystem
<builder@dreamos-buildsystem.local>`, random 32-char passphrase in
`~/.gnupg/passphrase` (mode 0600). Lives on the host bind-mount →
persists across container restarts, shared across all BuildEnvs.

Block that lands in `conf/local-ext.conf` (uncommented on opendreambox):

```sh
PACKAGE_FEED_SIGN = '1'
PACKAGE_CLASSES = "package_deb sign_package_feed"
PACKAGE_FEED_GPG_BACKEND = 'local'
PACKAGE_FEED_GPG_SIGNATURE_TYPE = 'BIN'
PACKAGE_FEED_GPG_NAME = "<auto-filled fingerprint>"
PACKAGE_FEED_GPG_PASSPHRASE_FILE = "/home/builder/.gnupg/passphrase"
```

Caveats:
- On dreamlegacy the block is commented — `DpkgIndexer` never reads
  the sign vars there. **IPK** feeds via `OpkgIndexer` do sign on
  both branches, so switch to `package_ipk` and uncomment if needed.
- Re-running `bootstrap-buildenv` reuses the existing keyring.
- Own key instead of auto-generated: drop `.gnupg/` into
  `~/dreamos-builds/.gnupg/` on the host BEFORE first start; make
  sure `~/.gnupg/passphrase` matches.

### Managing signing keys

All GPG commands run inside the container against `~/.gnupg/` (=
host `~/dreamos-builds/.gnupg/`, persistent).

**List keys**:

```sh
gpg --list-secret-keys --keyid-format=long
gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10}'
```

**Generate a new key manually**:

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

Paste the new fingerprint into `PACKAGE_FEED_GPG_NAME` in every
BuildEnv's `conf/local-ext.conf`.

**Import an existing key**:

```sh
gpg --import /path/to/private.asc
gpg --import /path/to/public.asc
FPR=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')
echo "$FPR:6:" | gpg --import-ownertrust
```

**Export the public key** (for STB / test client):

```sh
gpg --armor --export builder@dreamos-buildsystem.local > dreamos-buildsystem-feed-pubkey.asc
# On the STB: apt-key add dreamos-buildsystem-feed-pubkey.asc
```

**Rotate / remove**:

```sh
gpg --delete-secret-keys <FINGERPRINT>
gpg --delete-keys        <FINGERPRINT>
```

After rotation update `PACKAGE_FEED_GPG_NAME` and re-distribute the
public key.

### Hosting your own feed

After `MACHINE=xxx make image`, artefacts land in:

```
build/<MACHINE>/tmp/deploy/deb/
                          ├── all/
                          ├── <MACHINE>/
                          ├── cortexa15hf-neon-vfpv4/
                          └── ...
```

A "feed" is that directory tree served over HTTP(S) with generated
index files (`Packages`, `Packages.gz`, `Release` [+ `Release.gpg`
if signing]).

1. **Feed indexes** are written automatically by `do_rootfs` in
   [oe/rootfs.py:650](https://git.openembedded.org/openembedded-core/tree/meta/lib/oe/rootfs.py?h=pyro)
   via `pm.write_index() → DpkgIndexer`. After `make image`, the
   feed is index-ready on disk.

   You only need `make package-index` explicitly when you built
   individual packages with `bitbake <pkg>` (no `do_rootfs`, no
   auto-refresh).

2. **Publish** the entire `tmp/deploy/deb/` tree over HTTP — nginx,
   apache, caddy, any static file server. Match the URL layout to
   `DISTRO_FEED_URI`, e.g. `.../opendreambox/2.5/unstable/…` for a
   krogoth-based box like `dm900`, `.../opendreambox/2.6/unstable/…`
   for a pyro-based box like `dreamtwo`.

3. **Point `DISTRO_FEED_URI`** at your host, rebuild the image,
   install → the receiver's `sources.list.d/*.list` now references
   your URL.

4. **If signing is on**: distribute the public key (`gpg --armor
   --export > pubkey.asc`) to receivers. On the STB: `apt-key add
   pubkey.asc`, or bake it into the image via a custom recipe
   dropping the armored key into `/etc/apt/trusted.gpg.d/`.

Common workflow:

```sh
MACHINE=dm900 make image
# Indexes already written under build/dm900/tmp/deploy/deb/
# dm900 = krogoth → 2.5. For pyro (dreamone/dreamtwo) use 2.6.
rsync -a build/dm900/tmp/deploy/deb/ user@feedhost:/var/www/opendreambox/2.5/unstable/
```

Yocto reference (same mechanism, all OE-based distros):
<https://docs.yoctoproject.org/dev-manual/packages.html#creating-and-using-a-package-feed>.

## Architecture — three images composed on the registry

The consumable `dreamos-buildsystem-ubnt18` isn't built from a
Dockerfile — it's composed at the OCI manifest level from two smaller
images. No consumer needs to know this; `docker pull ubnt18:latest`
gets the composed image directly.

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

**Why the split:**
- **base** rebuilds on every code/ESM change. Small (~1.2 GB), CI ~5 min.
- **sources** rebuilds only when the OE downloads snapshot needs
  refreshing (rare, manual on the build server). Docker layer is
  ~19 GB (raw `sources-seed/` is ~11 GB — the layer adds tar metadata
  for ~1200 files + git-mirror objects).
- **ubnt18** composed from base + sources via `regctl` + OCI
  cross-repo blob mount. No layer blobs downloaded during
  composition. ~30 sec on a stock GHA runner.

**Consumer cost after a fresh base release:** sources layer unchanged
→ already cached by Docker → only ~1.2 GB new toolchain layer pulled.
First-time full pull: ~19 GB compressed.

### Composition mechanics

- Fetch manifests + configs of base and sources (kilobytes, no blob downloads)
- Diff the layer sets: identify layers in sources but not in base = the `/opt/dl-mirror` layer(s)
- Cross-repo-mount those layer blobs from sources package → ubnt18 package (OCI standard, server-side, zero bytes on runner)
- Craft new config JSON = base's runtime settings + sources' rootfs additions
- Push composed manifest as `dreamos-buildsystem-ubnt18:<version>`

Total: ~30 sec on a stock GHA runner. No 11 GB pull, no build.

### Manual composition (build server, after sources refresh)

```sh
regctl registry login ghcr.io -u <you> -p <PAT_with_write_packages>

DST=ghcr.io/wxbet-org/dreamos-buildsystem-ubnt18:v0.3.0 \
    ./compose.sh

# Or with explicit base/sources tags:
BASE=ghcr.io/wxbet-org/dreamos-buildsystem-base:v0.3.0 \
SOURCES=ghcr.io/wxbet-org/dreamos-buildsystem-sources:2026-07-20 \
DST=ghcr.io/wxbet-org/dreamos-buildsystem-ubnt18:v0.3.0 \
    ./compose.sh
```

## Release

**One tag does the whole release.** Push
`dreamos-buildsystem-ubnt18/vX.Y.Z`:

1. CI builds base with fresh apt/ESM patches (`--no-cache`), pushes
   `dreamos-buildsystem-base:vX.Y.Z` + `:latest`
2. Composes ubnt18 on ghcr from just-built base + current
   `dreamos-buildsystem-sources:latest`, pushes
   `dreamos-buildsystem-ubnt18:vX.Y.Z` + `:latest`

```sh
git tag dreamos-buildsystem-ubnt18/v0.3.0
git push origin dreamos-buildsystem-ubnt18/v0.3.0
```

~5 min phase 1 (apt install), ~30 sec phase 2 (regctl compose).

Base + ubnt18 share the version number by design — every ubnt18
release is a matched pair with its base.

The sources image has its own release cadence, built + tagged
manually on the build server. Refreshing sources requires a
subsequent ubnt18 release to compose it in.

### Base-only iteration

Trigger the `dreamos-buildsystem-ubnt18` workflow via
**workflow_dispatch** from the Actions tab. Phase 1 runs with
`push: false` — base builds to prove Dockerfile / apt / ESM still
work, no bytes on GHCR. Phase 2 skipped.

### `:latest` promotion

Both base and ubnt18 `:latest` updated only when the pushed version
is the highest sortable `dreamos-buildsystem-ubnt18/*` tag
(`git tag -l ... | sort -V | tail -1`). Guards against a late
hotfix on an older branch accidentally overwriting `:latest`.
