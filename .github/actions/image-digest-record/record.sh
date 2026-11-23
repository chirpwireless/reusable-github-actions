#!/usr/bin/env bash
# Writes one IMAGE:TAG@DIGEST line to a file of its own and names the artifact after the image.
set -euo pipefail
owner=${GITHUB_REPOSITORY_OWNER,,}
[[ $IMAGE =~ ^ghcr\.io/${owner}/[a-z0-9][a-z0-9._/-]{0,127}$ ]] || { echo "::error::image '$IMAGE' is not ghcr.io/$owner/<name>"; exit 1; }
[[ $TAG =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] || { echo "::error::tag '$TAG' is not a Docker tag"; exit 1; }
[[ $DIGEST =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::digest '$DIGEST' is not sha256:<64 hex>"; exit 1; }
name="image-digest-${IMAGE#ghcr.io/"$owner"/}"
name=${name//\//_}
dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/image-digest.XXXXXX")
printf '%s:%s@%s\n' "$IMAGE" "$TAG" "$DIGEST" > "$dir/pin.txt"
{ echo "name=$name"; echo "path=$dir/pin.txt"; } >> "$GITHUB_OUTPUT"
