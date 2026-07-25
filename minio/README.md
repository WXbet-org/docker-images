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

Run the following once — creates the three buckets, sets
anonymous-read on the two read-only mirrors, and adds a `builder`
service user that the orchestrator uses to write back after each
build.

Install `mc` (MinIO Client) locally, or run it in a throwaway
container:

```sh
alias mc='docker run --rm --network oea-build -e MC_HOST_local=http://admin:<PW>@minio:9000 minio/mc:latest'
```

Then:

```sh
# Buckets
mc mb local/sstate-openatv-6.0
mc mb local/downloads
mc mb local/deploy-openatv-6.0

# Anonymous read for the two mirrors so bitbake needs no credentials
mc anonymous set download local/sstate-openatv-6.0
mc anonymous set download local/downloads

# `deploy` intentionally stays private -- if you publish it,
# do it via a separate nginx sidecar that reads from a signed URL
# or copies to a public bucket / rsync target.

# Service user for post-build sync (orchestrator uses these creds)
mc admin user add local builder <BUILDER_SECRET_KEY>
mc admin policy attach local readwrite --user builder
```

Verify:

```sh
mc anonymous get local/sstate-openatv-6.0        # should say "download"
mc admin user list local                          # should list `builder`
```

## Consuming from build containers

Build containers join the same network and reach MinIO by hostname.
Wire it into the entrypoint via env-vars:

```sh
docker run --rm \
    --network oea-build \
    -e MACHINE=dm900 \
    -e SSTATE_MIRROR_URL=http://minio:9000/sstate-openatv-6.0 \
    -e DL_MIRROR_URL=http://minio:9000/downloads \
    -v <ephemeral sstate volume>:/sstate-cache \
    -v <shared deploy volume>:/deploy \
    ghcr.io/wxbet-org/oea-buildsystem:6.0
```

Bitbake internally translates that into:

```
SSTATE_MIRRORS = "file://.* http://minio:9000/sstate-openatv-6.0/PATH"
PREMIRRORS     = "<protocol>://.*/.*  http://minio:9000/downloads/"
```

(entrypoint writes those lines into `conf/site.conf` when the two
env-vars are set).

## Post-build sync (from the orchestrator)

After a successful build, the orchestrator (Argo / GHA / cron)
syncs the container's local sstate + deploy back to MinIO. `mc
mirror --overwrite --newer` is idempotent and only transfers deltas:

```sh
# Uses builder-service-account credentials
alias mc-writer='docker run --rm --network oea-build \
    -e MC_HOST_local=http://builder:<BUILDER_SECRET>@minio:9000 \
    -v <ephemeral sstate volume>:/sstate-cache:ro \
    -v <shared deploy volume>:/deploy:ro \
    minio/mc:latest'

mc-writer mirror --overwrite --newer /sstate-cache/ local/sstate-openatv-6.0/
mc-writer mirror --overwrite --newer /deploy/       local/deploy-openatv-6.0/
```

Then the orchestrator prunes the ephemeral sstate-cache volume;
`/deploy` can stay for the next `mc mirror` cycle or be cleared
after fan-in.

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
