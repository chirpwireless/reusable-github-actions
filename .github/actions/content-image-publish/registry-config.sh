#!/usr/bin/env bash
# Prints the config digest of <image:tag> in the registry, or "absent" when the registry answers 404; any other answer fails.
set -euo pipefail

ref=${1:?image:tag}
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/registry-config.XXXXXX")
trap 'rm -rf "$work"' EXIT

if ! docker buildx imagetools inspect --raw "$ref" > "$work/manifest" 2> "$work/err"; then
  case "$(cat "$work/err")" in
    *": not found") echo absent; exit 0 ;;
    *) echo "::error::cannot inspect $ref: $(cat "$work/err")" >&2; exit 1 ;;
  esac
fi
media=$(jq -r '.mediaType // empty' "$work/manifest")
case "$media" in
  application/vnd.docker.distribution.manifest.v2+json|application/vnd.oci.image.manifest.v1+json) ;;
  *) echo "::error::$ref is not a single-platform image manifest (mediaType '$media')" >&2; exit 1 ;;
esac
config=$(jq -r '.config.digest // empty' "$work/manifest")
printf '%s' "$config" | grep -Eqx 'sha256:[0-9a-f]{64}' || { echo "::error::$ref has no valid config digest" >&2; exit 1; }
echo "$config"
