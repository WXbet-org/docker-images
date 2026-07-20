#!/usr/bin/env bash
# Compose the consumable dreamos-buildsystem-ubnt18 image from
# dreamos-buildsystem-base + the dl-mirror layer of dreamos-buildsystem-sources.
#
# All work happens at the registry manifest level using regctl (regclient):
# manifests and configs (kilobytes) are fetched, but the ~11 GB sources
# layer blob is NOT downloaded. It's cross-repo-mounted server-side from
# the sources package into the ubnt18 package. Runtime: seconds, not minutes.
#
# Prerequisites:
#   * regctl in PATH  (https://regclient.org)
#   * Logged in to ghcr.io with a token that has read+write on all three
#     packages (base, sources, ubnt18). GITHUB_TOKEN in a workflow works
#     if all packages grant the repo admin-level Actions access.
#
# Env:
#   BASE      full ref of base image           (default: ghcr.io/wxbet-org/dreamos-buildsystem-base:latest)
#   SOURCES   full ref of sources image        (default: ghcr.io/wxbet-org/dreamos-buildsystem-sources:latest)
#   DST       full ref of ubnt18 image to push (required)
#   PLATFORM  platform for resolving indices   (default: linux/amd64)
set -euo pipefail

BASE="${BASE:-ghcr.io/wxbet-org/dreamos-buildsystem-base:latest}"
SOURCES="${SOURCES:-ghcr.io/wxbet-org/dreamos-buildsystem-sources:latest}"
DST="${DST:?DST env var must be set (e.g. ghcr.io/wxbet-org/dreamos-buildsystem-ubnt18:v0.3.0)}"
PLATFORM="${PLATFORM:-linux/amd64}"

DST_REPO="${DST%:*}"

command -v regctl >/dev/null || { echo "regctl not in PATH"; exit 1; }
command -v jq     >/dev/null || { echo "jq not in PATH"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo ">>> Resolving base image ($BASE) for $PLATFORM ..."
regctl manifest get --platform "$PLATFORM" --format body "$BASE"    > base.mf.json
BASE_CFG_DIGEST=$(jq -r '.config.digest' base.mf.json)
regctl blob get "$BASE" "$BASE_CFG_DIGEST" > base.cfg.json
BASE_MEDIATYPE=$(jq -r '.mediaType' base.mf.json)

echo ">>> Resolving sources image ($SOURCES) for $PLATFORM ..."
regctl manifest get --platform "$PLATFORM" --format body "$SOURCES" > src.mf.json
SRC_CFG_DIGEST=$(jq -r '.config.digest' src.mf.json)
regctl blob get "$SOURCES" "$SRC_CFG_DIGEST" > src.cfg.json

# Find layers present in sources but NOT in base = the sources-only extras.
# Both images start FROM ubuntu:18.04, so ubuntu layers are shared by digest.
BASE_LAYER_DIGESTS=$(jq -r '.layers[].digest' base.mf.json | sort -u | jq -R -s -c 'split("\n")|map(select(length>0))')
EXTRA_LAYERS=$(jq --argjson base_digests "$BASE_LAYER_DIGESTS" \
    '[.layers[] | select(.digest as $d | ($base_digests | index($d)) | not)]' \
    src.mf.json)
EXTRA_COUNT=$(jq 'length' <<<"$EXTRA_LAYERS")

if [ "$EXTRA_COUNT" -eq 0 ]; then
    echo "!!! No extra layers found in sources -- nothing to compose."
    exit 1
fi
echo ">>> Extra layers to mount from sources into ubnt18: $EXTRA_COUNT"
jq -r '.[] | "     \(.digest)  (\(.size) bytes)"' <<<"$EXTRA_LAYERS"

# The corresponding diff_ids are the last N entries of sources' rootfs.diff_ids
# (config diff_ids are 1:1 with manifest layers in order).
EXTRA_DIFFIDS=$(jq --argjson n "$EXTRA_COUNT" '.rootfs.diff_ids[(-$n):]' src.cfg.json)
EXTRA_HISTORY=$(jq --argjson n "$EXTRA_COUNT" '.history[(-$n):] // []' src.cfg.json)

echo ">>> Cross-repo-mounting extra layer blobs from sources into $DST_REPO ..."
SRC_REPO="${SOURCES%:*}"
for d in $(jq -r '.[].digest' <<<"$EXTRA_LAYERS"); do
    echo "    mounting $d"
    regctl blob copy "$SRC_REPO" "$DST_REPO" "$d"
done

echo ">>> Building composed config (base runtime + sources rootfs additions) ..."
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
