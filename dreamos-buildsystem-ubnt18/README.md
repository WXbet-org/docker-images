# dreamos-buildsystem-ubnt18

Container image for opendreambox / OE builds based on Ubuntu 18.04 + Ubuntu Pro (ESM).

## Purpose

Reproducible build environment for [opendreambox](https://github.com/WXbet/opendreambox). Provides the toolchain combination older opendreambox branches expect:

- Ubuntu 18.04.6 LTS
- gcc **6.5.0**
- Python 2.7.17 + Python 3.6.9

Because 18.04 has been out of standard support since April 2023, the build attaches Ubuntu Pro (ESM) so security updates from `esm-infra` / `esm-apps` are included. The token and Pro-client state do **not** end up in the final image.

## Prerequisites

1. **Docker with BuildKit** — enabled by default in current Docker Desktop / CE.
2. **Ubuntu Pro token** from [ubuntu.com/pro/dashboard](https://ubuntu.com/pro/dashboard). Free for up to 5 machines on the personal tier.
3. Enter the token into `pro-attach-config.yaml` (in this folder):

   ```sh
   cp pro-attach-config.yaml.example pro-attach-config.yaml
   # Replace YOUR_TOKEN_HERE with the real token
   ```

   The file is excluded from commits via `.gitignore` (repo-wide).

4. **Sources image** — the [`dreamos-buildsystem-sources`](../dreamos-buildsystem-sources/README.md) image must exist locally (or be pullable from a registry). It provides `/opt/dl-mirror` as a read-only, digest-stable base layer that this image extends via `FROM`. Build it once:

   ```sh
   (cd ../dreamos-buildsystem-sources && ./build.sh)
   ```

## Local build

Run all commands from **this folder**.

```sh
./build.sh
```

Or manually:

```sh
DOCKER_BUILDKIT=1 docker build . \
  --secret id=pro-attach-config,src=pro-attach-config.yaml \
  -t dreamos-buildsystem-ubnt18
```

## Using the image

The container expects one bind-mount from the host so downloads and BuildEnv checkouts persist across restarts:

| Host | Container | Purpose |
|---|---|---|
| `~/dreamos-builds/` | `/home/builder/` (= `~` inside container) | Everything the builder user does |

Note the mount target: `~/dreamos-builds` on the host is mounted **directly onto the builder user's home** — no extra folder level. The entrypoint seeds `.bashrc`/`.profile` from `/etc/skel` on first start so a fresh, empty mount still gives a normal shell.

Use the wrapper (creates the host dir if missing, publishes SSH on 2222):

```sh
./run.sh                                          # interactive bash
./run.sh bootstrap-buildenv opendreambox krogoth  # one-shot bootstrap
```

Or manually:

```sh
mkdir -p ~/dreamos-builds
docker run --rm -it \
  -p 2222:22 \
  -v ~/dreamos-builds:/home/builder \
  dreamos-buildsystem-ubnt18
```

The image runs as `builder` (UID 1000, password `builder`). Passwordless `sudo` is available; sshd is started by the entrypoint so `ssh builder@localhost -p 2222` works from the host.

### Bootstrapping a BuildEnv

**On the very first container start**, the entrypoint auto-runs `bootstrap-buildenv` for all four standard variants:

- `opendreambox/krogoth`, `opendreambox/pyro`
- `dreamlegacy/krogoth`, `dreamlegacy/pyro`

This takes several minutes (git clone + `make update` × 4). A marker file `~/.auto-bootstrap-done` is created after so subsequent starts skip it. To re-trigger, `rm ~/.auto-bootstrap-done` and restart. To skip on first start, run with `-e AUTO_BOOTSTRAP=0`.

You can also invoke it manually at any time:

```sh
bootstrap-buildenv opendreambox krogoth   # -> ~/opendreambox/krogoth
bootstrap-buildenv dreamlegacy pyro       # -> ~/dreamlegacy/pyro
```

What the script does (all idempotent — re-runs are safe):

1. Clones the fork/branch into `~/<fork>/<branch>/` (skipped if already cloned).
2. Runs `make update` (initialises submodules + BuildEnv config; skipped after first success via `.bootstrap-done` marker).
3. Creates the `sources` symlink pointing at `../../sources` (the shared, host-persistent DL_DIR at `~/sources`).
4. Writes `conf/local-ext.conf` with sensible defaults — **only if the file doesn't already exist**. This is the opendreambox convention: `MACHINE=… make init` generates `build/<MACHINE>/conf/local.conf` that auto-includes `../../conf/local-ext.conf` for user overrides. The per-machine `local.conf` is machine-generated and must never be hand-edited.

The default `local-ext.conf` covers PREMIRRORS (in-image sources snapshot), a personal MIRRORS fallback, OSCAM name/port, distro feed URI, and package signing (see below).

### GPG signing (optional)

If you use the `PACKAGE_FEED_SIGN` block in the default `local-ext.conf`, package signing needs a GPG keyring and passphrase file inside the container. Since `$HOME` is the host bind-mount, put them on the host:

```
~/dreamos-builds/.gnupg/                    # your keyring
~/dreamos-builds/.gnupg/passphrase          # plain text, chmod 600
```

They appear as `/home/builder/.gnupg/…` inside the container. If you don't need signing, comment out that block in `local-ext.conf` (or delete `local-ext.conf` and let bootstrap regenerate a modified version).

Result layout on the host (visible directly as `~/dreamos-builds/…`, inside the container as `~/…`):

```
~/dreamos-builds/         ~ inside container
├── sources/              # shared DL_DIR (persistent, grows over time)
├── dreamlegacy/
│   ├── pyro/             # git clone + submodules
│   │   ├── sources -> ../../sources
│   │   └── conf/local.conf
│   └── krogoth/ ...
└── opendreambox/
    ├── pyro/
    └── krogoth/
```

### How sources work

- `/opt/dl-mirror/` (baked into the image, read-only) is the **PREMIRROR** — bitbake looks here first.
- `~/sources/` inside the container (= `~/dreamos-builds/sources/` on the host, writable) is the **DL_DIR** — anything not found in the premirror is fetched from the network and lands here.
- The download pool accumulates on the host, survives image rebuilds, is shared across every BuildEnv variant.

### Refreshing the in-image PREMIRROR

Fresh downloads that accumulate in `~/dreamos-builds/sources/` (from every `make download`) can be folded back into the sources image so the next build's PREMIRROR hit rate improves. Workflow: `rsync --safe-links` the host `sources/` into `dreamos-buildsystem-sources/sources-seed/`, rebuild the sources image, rebuild this toolchain image. Full commands in [`../dreamos-buildsystem-sources/README.md`](../dreamos-buildsystem-sources/README.md#ongoing-updates-from-a-running-container).

## Design decisions

**Why a fixed `/etc/machine-id`?** Without a fixed value, every build would register as a NEW machine with Canonical and consume one of the 5 personal-tier slots inside the 24-hour window — after a handful of rebuilds on the same day the limit would be hit. The hard-coded value (`md5("dreamos-buildsystem-ubnt18")`) makes Canonical always see the same machine and recycles the slot. No secret, safe to keep in the image.

**Why everything in a single `RUN`?** The Pro-client token and attach state must not remain in any layer or in the layer history. Attach → upgrade → install → detach → purge in the same `RUN` guarantees that.

**Why the `trap 'pro detach ... EXIT'`?** If the build aborts mid-run (error, Ctrl-C, OOM), the machine would otherwise stay attached in the Pro dashboard longer than needed. The trap always cleans up.

**Why `old-releases.ubuntu.com`?** The 18.04 packages have been moved out of the default mirrors. sources.list is rewritten directly, otherwise the initial `apt-get update` fails.

**Why `ubuntu-advantage-tools` instead of `ubuntu-pro-client`?** Compatibility with 18.04 — the newer package name only works cleanly on more recent releases.

## What ESM in the image means

After detach, the ESM packages remain installed, but the ESM repos are removed. The image is a **snapshot** of all ESM patches available at build time. To pick up newer patches: rebuild the image (standard container pattern).

## CI / publishing to ghcr.io

The workflow [.github/workflows/dreamos-buildsystem-ubnt18.yml](../.github/workflows/dreamos-buildsystem-ubnt18.yml) builds the image on every push of an image-prefixed tag and pushes to:

```
ghcr.io/wxbet-org/dreamos-buildsystem-ubnt18:<version>
ghcr.io/wxbet-org/dreamos-buildsystem-ubnt18:latest   (only if <version> is the highest)
```

**Tag convention** (because the repo hosts multiple images):

```
dreamos-buildsystem-ubnt18/<version>
```

The prefix before `/` decides which workflow triggers. The part after it becomes the docker tag 1:1.

**Example release:**

```sh
git tag dreamos-buildsystem-ubnt18/v0.1.0
git push origin dreamos-buildsystem-ubnt18/v0.1.0
```

Result: `ghcr.io/wxbet-org/dreamos-buildsystem-ubnt18:v0.1.0` and (if this is the highest version for this image) `:latest`.

`:latest` is only overwritten when the pushed version is the highest sortable version for this image (`git tag -l 'dreamos-buildsystem-ubnt18/*' | sort -V`). Tags of other images in the same repo are ignored.

### One-time setup

Under **Settings → Secrets and variables → Actions**, add a secret:

- `UBUNTU_PRO_TOKEN` — the token from [ubuntu.com/pro/dashboard](https://ubuntu.com/pro/dashboard)

The workflow builds `pro-attach-config.yaml` from it at runtime and passes it as a BuildKit secret — the token ends up neither in the image nor in the Actions logs.

Auth to ghcr.io uses the built-in `GITHUB_TOKEN` with `packages: write`. Because the repo lives under `WXbet-org` (the same org that owns the packages), no PAT is needed.

### Consuming the image

```sh
docker pull ghcr.io/wxbet-org/dreamos-buildsystem-ubnt18:latest
docker run --rm -it ghcr.io/wxbet-org/dreamos-buildsystem-ubnt18:latest
```

For private packages, run `docker login ghcr.io` first with a PAT (`read:packages`).

## Checking Ubuntu Pro slots

- Dashboard: [ubuntu.com/pro/dashboard](https://ubuntu.com/pro/dashboard) shows the number of active machines. "Active" means: contacted within the last 24 hours.
- After `pro detach`, the counter can take up to 24 hours to go down.
- Slots left over from aborted builds are what the trap construct above prevents.
