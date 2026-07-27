# dreamos-buildsystem-feed

Tiny Caddy-based HTTP(S) server that publishes the .deb feed produced
by [`dreamos-buildsystem-ubnt18`](../) so
opkg on the target box can install packages from it.

## Design in one paragraph

`ghcr.io/wxbet-org/dreamos-buildsystem-feed` -- stock `caddy:2` with
this dir's `Caddyfile` + `entrypoint.sh` baked in, so the compose
file is fully self-contained (no sibling files needed at deploy time
-- Portainer-friendly). Version-locked to the same tag as its
sibling `dreamos-buildsystem-ubnt18` image so the two always match.

At container start (and every `RESCAN_INTERVAL` seconds after) the
entrypoint scans the read-only build volume at `/home/builder` and
materializes a clean symlink tree under `/srv/feed`. Each existing
MACHINE build gets one symlink directly at its `tmp-glibc/deploy/`
dir, so the URL layout the box sees matches the on-disk layout 1:1
-- no URL-rewriting logic on the Caddy side, no fiddling with
bitbake internals, and nothing outside the deploy dirs is
HTTP-reachable (sources/, .git/, tmp-glibc/work/, sstate/, ... stay
physically mounted but Caddy is rooted at `/srv/feed`, not at the
build volume, so there's no URL path that reaches them).

Two variants matching the build stack's storage modes:

| Feed compose file | Reads from                              | Pair with build stack       |
|-------------------|-----------------------------------------|-----------------------------|
| `docker-compose.volume.yaml` | Named Docker volume       | build stack in `volume` mode |
| `docker-compose.mount.yaml`  | Host path (bind-mount)    | build stack in `mount` mode  |

## What Caddy exposes

Everything under `/srv/feed` after the symlink pass. Concretely:

```
/                                            ← Caddy's root
├── opendreambox/
│   └── krogoth/
│       └── unstable/                        ← DISTRO_FEED_CHANNEL
│           └── dm900/                       ← REAL directory
│               ├── deb/    →  <build>/.../deploy/deb
│               └── images/ →  <build>/.../deploy/images/dm900
└── dreamlegacy/
    └── pyro/
        └── ...
```

The per-MACHINE dir is a real directory with two symlinks: `deb`
covers the whole deb repository (so URL `.../<machine>/deb/<arch>`
resolves straight into the arch feed) and `images` exposes the
firmware artefacts. openembedded-core's `distro-feed-configs`
recipe writes URLs of the shape `<DISTRO_FEED_URI>/deb/<arch>` into
the box's opkg / apt config, so `bootstrap-buildenv` sets
`DISTRO_FEED_URI` to the machine-level URL and this layout matches.

The channel path segment comes from each branch's `local-ext.conf`
(`DISTRO_FEED_CHANNEL`) -- default `unstable`, override per stack by
editing that file before the first build.

## HTTP vs HTTPS

Two modes toggled by env-var, no config change:

| `FEED_DOMAIN`         | Behaviour                                        |
|-----------------------|--------------------------------------------------|
| unset (default)       | Plain HTTP on `${FEED_HTTP_PORT:-8080}`          |
| e.g. `feed.example.com` | Caddy provisions a Let's Encrypt cert automatically and serves HTTPS on `${FEED_HTTPS_PORT:-8443}`; HTTP on 80 stays up so the ACME HTTP-01 challenge can complete |

When you switch to a public domain, `FEED_ACME_EMAIL` is used to
register the LE account. Default is `admin@${FEED_DOMAIN}`; override
if that alias doesn't reach a human.

Ports 80 and 443 in the container map to `FEED_HTTP_PORT` /
`FEED_HTTPS_PORT` on the host. Defaults 8080 / 8443 so nothing clashes
with a host-side proxy. For a real public feed, override to
`FEED_HTTP_PORT=80` + `FEED_HTTPS_PORT=443` so LE HTTP-01 and browser
HTTPS both work without a front-end proxy.

## Deploying

### Volume variant (build stack in `volume` mode)

```sh
# The named volume the build stack created. Default matches the
# out-of-the-box compose project name of dreamos-buildsystem-ubnt18.
export BUILD_VOLUME=dreamos-builder_ci_dreamos_build_data

# Internal / HTTP only
docker compose -f docker-compose.volume.yaml up -d
# -> deb feed at http://<host>:8080/opendreambox/krogoth/unstable/dm900/
# -> images    at http://<host>:8080/opendreambox/krogoth/unstable/dm900/images/

# Public with automatic LE
FEED_DOMAIN=feed.example.com \
FEED_HTTP_PORT=80 \
FEED_HTTPS_PORT=443 \
    docker compose -f docker-compose.volume.yaml up -d
# -> deb feed at https://feed.example.com/opendreambox/krogoth/unstable/dm900/
# -> images    at https://feed.example.com/opendreambox/krogoth/unstable/dm900/images/
```

### Mount variant (build stack in `mount` mode)

```sh
# Points at the same host path the build stack's BUILDS_DIR mounts.
export BUILDS_DIR=/home/wxbet/dreamos-builds
docker compose -f docker-compose.mount.yaml up -d
```

## Wiring it into a built image

The URL baked into an image's `/etc/opkg/*.conf` at build time is
controlled by the `IMAGE_FEED_URL` env-var on the build stack (see
[`dreamos-buildsystem-ubnt18/README`](../README.md)).
Point it at whatever URL your `dreamos-buildsystem-feed` is reachable on:

```
IMAGE_FEED_URL=https://feed.example.com   # baked URL:
                                          #   https://feed.example.com/<fork>/<branch>/<CHANNEL>/<MACHINE>
```

`bootstrap-buildenv` on the build side appends the fork, branch, the
channel from `DISTRO_FEED_CHANNEL`, and the MACHINE -- nothing else.
That matches what dreamos-buildsystem-feed's symlink tree exposes here (the deb
subdirs are lifted directly into the machine dir, with a sibling
`images` symlink for firmware), so opkg on the box hits the .deb
repo directly with no rewriting in between.

## Rescan behaviour

`entrypoint.sh` runs one full scan of the build volume before caddy
starts (so the first HTTP request already sees a populated tree),
then re-scans every `RESCAN_INTERVAL` seconds (default `60`). New
MACHINEs finishing builds appear at the next rescan -- no container
restart. New .deb files landing in an already-symlinked deploy dir
appear immediately, because the symlink already points at the parent
dir.

## Files

- `entrypoint.sh` — scan + symlink logic, then hands off to caddy.
- `Caddyfile` — server config; ~10 lines, no rewrite.
- `docker-compose.volume.yaml` — attaches to the shared build stack
  volume.
- `docker-compose.mount.yaml` — bind-mounts a host path.

## Not in scope

- Package signing: signing happens at build time inside
  dreamos-buildsystem (see the `PACKAGE_FEED_SIGN` block in
  `local-ext.conf`). This feed just serves whatever the build wrote.
- Feed pruning / retention: manual for now. When disk pressure
  becomes real, add a periodic job on the host that
  `find`s + deletes stale `PR` subtrees under
  `<build-root>/<fork>/<branch>/build/`.
