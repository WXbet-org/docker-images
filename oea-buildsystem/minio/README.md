# minio — object store for the oea-buildsystem pipeline

Runs a single MinIO instance that serves three roles for the
OE-Alliance build farm (OpenATV and any other distro built from the
`oe-alliance/build-enviroment` tree):

- **sstate-mirror** — read-only HTTP backstore for bitbake's
  `SSTATE_MIRRORS`. Every worker pulls hits from here, misses are
  computed locally and synced back after successful build.
- **downloads mirror** — HTTP cache for `PREMIRRORS`. Cold builds
  populate it; warm builds skip upstream fetches entirely.
- **deploy artefact store** — where every worker's per-MACHINE
  `.deb` + feed indexes end up after build.

All three are just S3 buckets on the same MinIO instance. Buckets
holding read-only mirrors get an anonymous-download policy so bitbake
doesn't need credentials on the read path. Write access uses a
dedicated service account.

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

Buckets are named per (DISTRO, BRANCH) tuple for sstate + deploy, and
one shared `sources` bucket for upstream tarballs (downloads are
distro-agnostic). Create the trio for each (DISTRO, BRANCH) you
build, and one `sources` bucket globally.

Below is the setup for the current default `openatv/6.0`. Repeat
the first three lines with a different `<DISTRO>-<BRANCH>` when you
add a new distro or branch.

Install `mc` (MinIO Client) locally, or run it in a throwaway
container:

```sh
alias mc='docker run --rm --network oea-build -e MC_HOST_local=http://admin:<PW>@minio:9000 minio/mc:latest'
```

Then:

```sh
# Buckets for the openatv/6.0 combination
DISTRO=openatv
BRANCH=6.0
mc mb "local/sstate-${DISTRO}-${BRANCH}"
mc mb "local/deploy-${DISTRO}-${BRANCH}"

# Global sources bucket (only once, not per distro/branch)
mc mb local/sources

# Anonymous read for the two mirror buckets that bitbake pulls from
mc anonymous set download "local/sstate-${DISTRO}-${BRANCH}"
mc anonymous set download local/sources

# `deploy-*` intentionally stays private -- if you publish it, do it
# via a separate nginx sidecar that reads from a signed URL or copies
# to a public bucket / rsync target.

# Service user for the entrypoint's post-MACHINE sync (write access
# to sstate + sources + deploy buckets).
#
# The second arg to `admin user add` is a secret key of YOUR choice
# (min. 8 chars). Pick something long + random -- generate with e.g.
# `openssl rand -base64 32` or `pwgen 32 1`. Save it somewhere
# durable (password manager, Komodo stack secrets, ...) because MinIO
# won't show it again after this command runs.
BUILDER_SECRET=$(openssl rand -base64 32)
echo "SAVE THIS: MINIO_SECRET_KEY for the oea build stacks = $BUILDER_SECRET"

mc admin user add local builder "$BUILDER_SECRET"
mc admin policy attach local readwrite --user builder
```

Later, in each oea build stack's Komodo/compose env:
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

## Consuming from build containers

Build containers join the same network and reach MinIO by hostname.
The oea-buildsystem entrypoint reads two URLs for the read side and
three credentials for the write side:

```sh
docker run --rm \
    --network oea-build \
    -e MACHINES="dm900 dm920" \
    -e BRANCH=6.0 \
    -e DISTRO=openatv \
    -e SSTATE_MIRROR_URL=http://minio:9000/sstate-openatv-6.0 \
    -e SOURCES_MIRROR_URL=http://minio:9000/sources \
    -e MINIO_HOST=minio:9000 \
    -e MINIO_ACCESS_KEY=builder \
    -e MINIO_SECRET_KEY=<BUILDER_SECRET_KEY> \
    -v oea_temp:/temp \
    -v oea_sstate:/sstate-cache \
    -v oea_sources:/sources \
    -v oea_deploy:/deploy \
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
For every MACHINE in `$MACHINES`:

```
mc mirror --overwrite --newer /sstate-cache/   local/sstate-${DISTRO}-${BRANCH}/
mc mirror --overwrite --newer /sources/        local/sources/
# on success only:
mc mirror --overwrite --newer /deploy/<MACHINE>/  local/deploy-${DISTRO}-${BRANCH}/<MACHINE>/
```

So warm sstate flows to MinIO in real time as MACHINEs finish, not
at the end of a 50-MACHINE batch. A container that dies at MACHINE
30/50 still leaves 29 MACHINEs worth of sstate + deploy on MinIO for
the next attempt or other concurrent containers.

## Backup

The `minio_data` volume IS the source of truth for the whole sstate
+ feed history. Nightly snapshot recommended:

```sh
docker run --rm \
    -v minio_minio_data:/data:ro \
    -v "$PWD/backups":/backup \
    alpine tar czf "/backup/minio-$(date +%Y%m%d).tgz" -C /data .
```

Restore: stop MinIO, wipe the volume, untar back into
`/var/lib/docker/volumes/minio_minio_data/_data/`, start again.

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
