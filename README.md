# docker-images

Container images for WXbet-org, published to
[ghcr.io/wxbet-org](https://github.com/orgs/WXbet-org/packages).

Three independent build systems live in this repo. Pick the one that
matches what you want to build and follow its README:

| Build system | Target | Details |
|---|---|---|
| [**oea-buildsystem**](oea-buildsystem/README.md) | OpenATV (and any other distro built from `oe-alliance/build-enviroment`) | Continuous MACHINE-loop containers, four ready-made compose stacks (batch loop × dev × mount × volume). Uses [**minio**](oea-buildsystem/minio/README.md) (part of this stack, deploy-once-per-farm) as shared sstate / sources / deploy cache. |
| [**dreamos-buildsystem-ubnt18**](dreamos-buildsystem-ubnt18/README.md) | opendreambox / dreamlegacy (krogoth + pyro) | Reproducible Ubuntu 18.04 + Pro/ESM toolchain with a baked-in ~11 GB `/opt/dl-mirror` sources snapshot. Package-feed hosting, signing, and multi-MACHINE compose variants. |
| [**simplebuild4**](simplebuild4/README.md) | s4 build system TUI (source in GitLab) | Container-packaged release triggered from the GitLab s4 repo via `repository_dispatch`. |

## Host prerequisites

The rest of this README covers the one-time Docker host setup that
applies regardless of which build system you run. All three
sub-projects assume a working Docker Engine + Compose plugin, and
Portainer/Komodo works with any of them if you want a web UI.

### 1. Install Docker

On Debian / Ubuntu:

```sh
sudo apt update
sudo apt install -y docker.io docker-compose-v2
sudo systemctl enable --now docker
sudo usermod -aG docker $USER    # so `docker` works without sudo
newgrp docker                    # activate the group in the current shell
```

Two packages suffice: `docker.io` is the daemon + CLI,
`docker-compose-v2` provides the modern `docker compose …` subcommand
(needed for every compose file in this repo). Everything sits in the
standard Ubuntu repo — no third-party PPA required.

If you also want to *build* multi-arch container images on this host
(not needed for consuming what's already on ghcr), add `docker-buildx`
to the apt line.

Distro too old and the pull fails? Install Docker CE from the
official repo instead: <https://docs.docker.com/engine/install/>.

Windows / macOS: install Docker Desktop and skip to the per-project
READMEs.

### 1a. Log rotation

Docker's default JSON logging driver has no rotation — a long-running
build container can fill the host disk with `docker logs` output.
One-time host config:

```sh
sudo tee /etc/docker/daemon.json > /dev/null <<EOF
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

Each container is now capped at 5 × 50 MB = 250 MB of history, older
lines rotate out. Applies to every container going forward. Existing
containers need a `docker restart <name>` to pick up the new driver.

### 1b. Optional: Portainer or Komodo for a web UI

Either works. Both let you deploy compose stacks straight from this Git repo.

**Portainer** — single container, HTTPS UI:

```sh
docker volume create portainer_data
docker run -d --name portainer \
    --restart=always \
    -p 8000:8000 -p 9443:9443 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest
```

Then browse to `https://<host>:9443`. First admin creation has a
**5-minute window** after container start; if you miss it, restart
the container and grab the setup token:

```sh
docker logs portainer 2>&1 | grep -i 'setup_token'
```

Paste the token into the browser field and continue with admin
creation. Local access from the same host doesn't need the token.

Port `9443` = UI, `8000` = Edge-Agent (skip if you only manage this
host locally).

**Komodo** — multi-host orchestrator, meant for a small farm.
Deployed once on a coordinator VM plus a `komodo-periphery` container
on each build host. Deploys stacks from Git repos, tails their logs,
provides SSH-into-container terminals. See Komodo's own docs for setup.

## Repo layout

```
.
├── oea-buildsystem/                    Consumable image landing (compose.sh + 4 compose files + README)
│   ├── oea-buildsystem-base/           Base image (Dockerfile + entrypoint + mcli + oea-retry)
│   ├── oea-buildsystem-repo/           Content image with build-enviroment tree (FROM scratch)
│   └── minio/                          Companion object-store stack (used only by oea)
├── dreamos-buildsystem-ubnt18/         Consumable image landing (compose.sh + compose files + README)
│   ├── dreamos-buildsystem-base/       Base image (toolchain-only)
│   └── dreamos-buildsystem-sources/    Data image (baked-in dl-mirror)
├── simplebuild4/                       s4 packaging (Dockerfile + compose)
└── .github/workflows/                  Release CI for each build system + weekly ghcr cleanup
```

## Contributing

- Each build system's docs live in its own directory's README.
  Cross-refs there rather than growing this landing page.
- Never commit `pro-attach-config.yaml`, `.env`, or anything with
  credentials — see `.gitignore`.
- Sources snapshots (`sources-seed/`) are host-rsync targets, not
  committed to git.
