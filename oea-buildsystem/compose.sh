#!/usr/bin/env bash
# Compose the consumable oea-buildsystem image from
# oea-buildsystem-base + oea-buildsystem-repo.
#
# All work happens at the registry manifest level using regctl (regclient):
# manifests and configs (kilobytes) are fetched, but layer blobs are NOT
# downloaded -- they are cross-repo-mounted server-side from base + repo
# into the composed target. Runtime: seconds, not minutes.
#
# Prerequisites:
#   * regctl in PATH  (https://regclient.org)
#   * jq in PATH
#   * Logged in to ghcr.io with a token that has read+write on all three
#     packages (base, repo, composed). GITHUB_TOKEN in a workflow works
#     if all packages grant the repo admin-level Actions access.
#
# Env:
#   BASE      full ref of base image           (default: ghcr.io/wxbet-org/oea-buildsystem-base:latest)
#   REPO      full ref of repo image           (required, e.g. ghcr.io/wxbet-org/oea-buildsystem-repo:6.0)
#   DST       full ref of composed image       (required, e.g. ghcr.io/wxbet-org/oea-buildsystem:6.0)
#   PLATFORM  platform for resolving indices   (default: linux/amd64)
set -euo pipefail

BASE="${BASE:-ghcr.io/wxbet-org/oea-buildsystem-base:latest}"
REPO="${REPO:?REPO env var must be set (e.g. ghcr.io/wxbet-org/oea-buildsystem-repo:6.0)}"
DST="${DST:?DST env var must be set (e.g. ghcr.io/wxbet-org/oea-buildsystem:6.0)}"
PLATFORM="${PLATFORM:-linux/amd64}"

# OCI-side repository paths (image ref without :tag). Named per dreamos
# compose.sh convention: DST_REPO = destination registry-repo,
# SRC_REPO = source registry-repo for the extra-layer blob mount.
DST_REPO="${DST%:*}"
SRC_REPO="${REPO%:*}"

command -v regctl >/dev/null || { echo "regctl not in PATH"; exit 1; }
command -v jq     >/dev/null || { echo "jq not in PATH"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo ">>> Priming target repo with base image (cross-repo blob mount, no download) ..."
# Copies the base image tag into the target repo. Since both live on the
# same registry (ghcr), all base layer blobs get cross-repo-mounted
# server-side -- no bytes leave the registry. The manifest at $DST is
# temporary; we overwrite it later with our composed one. But its blob
# references make the base layers valid targets for our composed manifest.
regctl image copy --fast "$BASE" "$DST"

echo ">>> Resolving base image ($BASE) for $PLATFORM ..."
regctl manifest get --platform "$PLATFORM" --format body "$BASE" > base.mf.json
BASE_CFG_DIGEST=$(jq -r '.config.digest' base.mf.json)
regctl blob get "$BASE" "$BASE_CFG_DIGEST" > base.cfg.json
BASE_MEDIATYPE=$(jq -r '.mediaType' base.mf.json)

echo ">>> Resolving repo image ($REPO) for $PLATFORM ..."
regctl manifest get --platform "$PLATFORM" --format body "$REPO" > repo.mf.json
REPO_CFG_DIGEST=$(jq -r '.config.digest' repo.mf.json)
regctl blob get "$REPO" "$REPO_CFG_DIGEST" > repo.cfg.json

# Repo image is FROM scratch, so every layer is an "extra" for the
# composed image. (In practice: exactly one layer -- the COPY repo/
# /work/ from oea-buildsystem-repo's Dockerfile.)
EXTRA_LAYERS=$(jq '.layers' repo.mf.json)
EXTRA_COUNT=$(jq 'length' <<<"$EXTRA_LAYERS")

if [ "$EXTRA_COUNT" -eq 0 ]; then
    echo "!!! Repo image has no layers -- nothing to compose."
    exit 1
fi
echo ">>> Layers to mount from repo image into composed image: $EXTRA_COUNT"
jq -r '.[] | "     \(.digest)  (\(.size) bytes)"' <<<"$EXTRA_LAYERS"

# All of the repo image's diff_ids and history entries are appended to base's.
EXTRA_DIFFIDS=$(jq '.rootfs.diff_ids' repo.cfg.json)
EXTRA_HISTORY=$(jq '.history // []' repo.cfg.json)

echo ">>> Cross-repo-mounting repo image layer blobs from $SRC_REPO into $DST_REPO ..."
for d in $(jq -r '.[].digest' <<<"$EXTRA_LAYERS"); do
    echo "    mounting $d"
    regctl blob copy "$SRC_REPO" "$DST_REPO" "$d"
done

echo ">>> Building composed config (base runtime metadata + repo rootfs) ..."
jq --argjson extra_diffids "$EXTRA_DIFFIDS" \
   --argjson extra_history "$EXTRA_HISTORY" \
   '.rootfs.diff_ids += $extra_diffids
    | .history       += $extra_history
    | .created        = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))' \
    base.cfg.json > new.cfg.json

# Upload new config as a blob to the target repo.
NEW_CFG_DIGEST=$(regctl blob put "$DST_REPO" < new.cfg.json)
NEW_CFG_SIZE=$(wc -c < new.cfg.json)
NEW_CFG_MEDIATYPE=$(jq -r '.config.mediaType' base.mf.json)

echo ">>> Composing manifest ..."
jq --arg   cfg_digest    "$NEW_CFG_DIGEST" \
   --argjson cfg_size     "$NEW_CFG_SIZE" \
   --arg   cfg_mediatype "$NEW_CFG_MEDIATYPE" \
   --argjson extras       "$EXTRA_LAYERS" \
   '.config.digest    = $cfg_digest
    | .config.size    = $cfg_size
    | .config.mediaType = $cfg_mediatype
    | .layers        += $extras' \
    base.mf.json > new.mf.json

echo ">>> Pushing composed manifest to $DST ..."
regctl manifest put --content-type "$BASE_MEDIATYPE" "$DST" < new.mf.json

echo ">>> Done."
regctl image digest "$DST"
