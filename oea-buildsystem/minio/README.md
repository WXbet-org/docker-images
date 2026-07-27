# minio — object store for the oea-buildsystem pipeline

Runs a single MinIO instance that serves two roles for the
OE-Alliance build farm (OpenATV and any other distro built from the
`oe-alliance/build-enviroment` tree):

- **sstate-mirror** — HTTP backstore for bitbake's `SSTATE_MIRRORS`.
  Every worker pulls hits from here, misses are computed locally and
  synced back after each MACHINE via `mcli mirror`.
- **sources mirror** — HTTP cache for `PREMIRRORS`. Cold builds
  populate it; warm builds skip upstream fetches entirely.

Both are S3 buckets on the same MinIO instance. Buckets get an
anonymous-download policy so bitbake doesn't need credentials on the
read path. Write access uses a dedicated service account (`builder`).

Deploy artefacts (kernel, rootfs, `.ipk` feeds) do NOT flow through
MinIO -- they live inside each build stack's own `<project>_temp`
Docker volume at `builds/.../$M/tmp/deploy/`. A downstream job (feed
hosting, rsync) can extract them from there via `docker cp` /
`docker run --volumes-from`. Deploy is per-stack, not shared: pseudo's
fd-tracking crashes across a symlink+cross-volume boundary in
`do_package_write_ipk`, so `tmp/deploy/` must sit on the same
filesystem as `tmp/work/`.

## Deploy

All commands assume you are on the Docker host that will run the
whole build pipeline (MinIO plus later the buildsystem workers).
Replace `<host>` in browser URLs with that host's reachable
address / hostname on your network.

**1. Create the shared docker network once.** Build containers will
join it too; MinIO must be reachable via its container hostname.
The `oea-build` name is what all our compose files reference.
Docker picks an unused RFC 1918 subnet automatically; the concrete
value doesn't matter as long as containers on the network can talk
to each other via hostnames.

```sh
docker network create oea-build
```

Verify:

```sh
docker network inspect oea-build --format \
    'name={{.Name}} driver={{.Driver}} scope={{.Scope}}'
# -> name=oea-build driver=bridge scope=local
```

**2. Set the admin password.** Never hardcode it into the compose
file (`docker inspect` reveals env vars in plaintext). Use a `.env`
file next to `docker-compose.yaml` (already gitignored by the
top-level `.gitignore` pattern) or export inline:

```sh
cat > .env <<'EOF'
MINIO_ROOT_USER=admin
MINIO_ROOT_PASSWORD=change-this-to-something-strong-min-8-chars
EOF
chmod 600 .env

docker compose up -d
```

**3. Verify.** Browser to `http://<host>:9001`, log in with the
credentials above.

## First-time bucket setup

One sstate bucket per (DISTRO, BRANCH) tuple, plus one global
`sources` bucket for upstream tarballs (distro-agnostic).

Below is the setup for the current default `openatv/6.0`. Repeat
the `sstate-…` line with a different `<DISTRO>-<BRANCH>` when you
add a new distro or branch. The `sources` bucket + service account
only get created once.

You have three options for running `mc` for the setup:

**A) Inside the running minio container** (simplest — `mc` is
already there, and `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD` env-vars
are visible so you don't have to type the password):

```sh
docker exec -it minio sh          # or your web UI's container console
# then, once inside:
export MC_HOST_local="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@localhost:9000"
mc admin info local                # sanity check -- should show server status
```

**B) Throwaway `mc` container on the same docker network**
(useful when you don't want to `exec` into minio):

```sh
alias mc='docker run --rm --network oea-build -e MC_HOST_local=http://admin:<PW>@minio:9000 minio/mc:latest'
```

**C) `mc` installed locally** — configure the alias explicitly:

```sh
mc alias set local http://<host>:9000 admin <PW>
```

Then all three variants share the same command syntax:

```sh
# Sstate bucket for the openatv/6.0 combination.
# Repeat this line for each additional (DISTRO, BRANCH) you build.
DISTRO=openatv
BRANCH=6.0
mc mb "local/sstate-${DISTRO}-${BRANCH}"

# Global sources bucket (only once, distro-agnostic upstream tarballs)
mc mb local/sources

# Anonymous read on both -- bitbake pulls without credentials.
mc anonymous set download "local/sstate-${DISTRO}-${BRANCH}"
mc anonymous set download local/sources

# Service user for the entrypoint's post-MACHINE sync (write access
# to sstate + sources buckets).
#
# The second arg to `admin user add` is a secret key of YOUR choice
# (min. 8 chars). Pick something long + random -- generated below
# from /dev/urandom (portable across busybox / alpine / ubuntu, no
# openssl needed since the minio container ships without it). Save
# the printed value somewhere durable (password manager, your
# orchestrator's stack secrets, ...) because MinIO won't show it
# again after this command runs.
BUILDER_SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '\n/+' | head -c 32)
echo "SAVE THIS: MINIO_SECRET_KEY for the oea build stacks = $BUILDER_SECRET"

mc admin user add local builder "$BUILDER_SECRET"
mc admin policy attach local readwrite --user builder
```

Later, in each oea build stack's env (`.env`, shell, or your
orchestrator's stack env):
```
MINIO_ACCESS_KEY=builder
MINIO_SECRET_KEY=<the value you saved above>
```

**Lost the key?** Rotate: `mc admin user remove local builder` then
run the `admin user add` line again with a fresh secret, and update
every stack's `MINIO_SECRET_KEY`.

Verify the setup:

```sh
mc anonymous get "local/sstate-${DISTRO}-${BRANCH}"   # -> "download"
mc admin user list local                              # lists `builder`
mc admin user info local builder                      # policy: readwrite
```

## Pre-seeding an existing sources directory

If you already have a populated OE downloads dir on the build host
(from a previous non-container-based build), upload it to the
`sources` bucket once so containers don't have to fetch from
upstream on first run.

Run this on the build host, with `<PATH>` = your existing dir
(e.g. `/home/wxbet/oe-alliance/sources`):

```sh
# Pull the admin creds out of the running minio container:
MINIO_ADMIN_USER=$(docker inspect minio --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^MINIO_ROOT_USER='     | cut -d= -f2)
MINIO_ADMIN_PASS=$(docker inspect minio --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^MINIO_ROOT_PASSWORD=' | cut -d= -f2)

# Throwaway mc container on the shared docker network,
# mount the existing sources dir read-only, mirror to MinIO:
docker run --rm --network oea-build \
    -v <PATH>:/src:ro \
    -e MC_HOST_local="http://${MINIO_ADMIN_USER}:${MINIO_ADMIN_PASS}@minio:9000" \
    minio/mc:latest \
    mirror /src/ local/sources/
```

Takes tens of minutes for a few GB (single-host loopback network, no
actual bytes leave the machine). Subsequent runs with the same
command are cheap because `mc mirror` skips already-present objects.

Verify afterwards from inside the minio container:

```sh
docker exec -it minio sh -c '
    export MC_HOST_local="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@localhost:9000"
    mc du local/sources/
    mc ls local/sources/ | head
'
```

## Consuming from build containers

Build containers join the same network and reach MinIO by hostname.
The oea-buildsystem entrypoint reads two URLs for the read side and
three credentials for the write side:

```sh
docker run --rm \
    --network oea-build \
    -e MACHINES="sf8008 vuzero4k" \
    -e BRANCH=6.0 \
    -e DISTRO=openatv \
    -e SSTATE_MIRROR_URL=http://minio:9000/sstate-openatv-6.0 \
    -e SOURCES_MIRROR_URL=http://minio:9000/sources \
    -e MINIO_HOST=minio:9000 \
    -e MINIO_ACCESS_KEY=builder \
    -e MINIO_SECRET_KEY=<BUILDER_SECRET_KEY> \
    -v <project>_temp:/temp \
    -v <project>_sstate:/sstate-cache \
    -v oea-buildsystem_sources:/sources \
    ghcr.io/wxbet-org/oea-buildsystem:6.0
```

Bitbake internally translates the two mirror URLs into:

```
SSTATE_MIRRORS = "file://.* http://minio:9000/sstate-openatv-6.0/PATH"
PREMIRRORS     = "<protocol>://.*/.*  http://minio:9000/sources/"
```

(entrypoint writes those lines into `conf/site.conf` when the
env-vars are set).

## Post-MACHINE sync (from inside the container)

The entrypoint does the sync itself after each MACHINE completes.
For every MACHINE in `$MACHINES`, whether the build succeeded or
failed:

```
mcli mirror --overwrite /sstate-cache/   local/sstate-${DISTRO}-${BRANCH}/
mcli mirror --overwrite /sources/        local/sources/
```

So warm sstate + fetched sources flow to MinIO in real time as
MACHINEs finish, not at the end of a 50-MACHINE batch. A container
that dies at MACHINE 30/50 still leaves 29 MACHINEs worth of sstate
on MinIO for the next attempt or other concurrent containers.

Deploy artefacts are NOT synced to MinIO -- they land inside each
stack's own `<project>_temp` volume at `builds/.../$M/tmp/deploy/`
and a separate publishing job extracts from there (see
[`oea-buildsystem/README.md`](../README.md)).

## Backup

The `<project>_data` volume IS the source of truth for the whole sstate
+ feed history. Nightly snapshot recommended:

```sh
docker run --rm \
    -v <project>_data:/data:ro \
    -v "$PWD/backups":/backup \
    alpine tar czf "/backup/minio-$(date +%Y%m%d).tgz" -C /data .
```

Restore: stop MinIO, wipe the volume, untar back into
`/var/lib/docker/volumes/<project>_data/_data/`, start again.

## Security notes

- **HTTP only** on the local network — for a `oea-build` docker
  bridge that's fine, container-to-container traffic doesn't leave
  the host.
- **Expose to the internet only via a reverse proxy with TLS** (nginx
  or Traefik doing Let's Encrypt in front of MinIO). Never publish
  port 9000 directly to the public internet with anonymous-read
  buckets — even without secrets, it's uncontrolled bandwidth.
- **`.env` with `MINIO_ROOT_PASSWORD`** is gitignored (or should be
  — verify with `git check-ignore -v .env`). Never commit.
- **Service accounts, not root credentials**, for the orchestrator's
  writes. The `builder` account above has `readwrite` policy scoped
  to any bucket; if you need per-bucket isolation, define custom
  policies with `mc admin policy create`.
