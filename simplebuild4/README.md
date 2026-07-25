# simplebuild4

Container-packaged release of the [s4 build system](https://git.streamboard.tv/common/simplebuild4).

The **source lives in GitLab**; this directory holds only:

- `Dockerfile` — Ubuntu 26.04 + s4 runtime + apt/pip deps
- `.dockerignore` — build-context filter
- `docker-compose.yaml` — user deployment one-liner

The release image ships as
`ghcr.io/wxbet-org/simplebuild4:<tag>` (and `:latest` when the
tag is the highest sortable one in the s4 GitLab repo).

## User deployment

Full docs — interactive TUI mode, headless web+mcp, data persistence,
updates — live in the s4 wiki:
<https://git.streamboard.tv/common/simplebuild4/-/wikis/getting-started/docker>.

## Release trigger flow

Fully automated end-to-end from a git tag in GitLab:

1. Someone pushes a git tag (e.g. `1.2.3`) to the GitLab s4 repo.
2. GitLab CI in that repo POSTs a `repository_dispatch` to this repo
   with event type `simplebuild4-release` and payload
   `{ tag, sha }`.
3. [`.github/workflows/simplebuild4.yml`](../.github/workflows/simplebuild4.yml)
   picks up the dispatch, clones s4 at the given SHA, overlays this
   directory's Dockerfile into the clone, and builds + pushes
   `ghcr.io/wxbet-org/simplebuild4:<tag>` (and `:latest` if
   this tag is the highest sortable one in s4).

There's no `push tags:` trigger on this side — everything comes from
GitLab. To trigger a rebuild without a new tag: manually invoke the
GitLab CI job for an existing tag.
