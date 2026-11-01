#!/usr/bin/env bash
set -euo pipefail

: "${IMAGE:?}" "${VERSION:?}" "${DIGEST:?}" "${REGISTRY:?}" "${GITHUB_REPOSITORY:?}"

owner=${GITHUB_REPOSITORY%%/*}
repo=${GITHUB_REPOSITORY#*/}
allowed="$(dirname "$0")/allowed-images.json"

fail() {
  echo "::error::$1"
  exit 1
}

[[ $IMAGE =~ ^[a-z0-9][a-z0-9._/-]*$ ]] || fail "image name '$IMAGE' is not valid"
[[ $VERSION =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] || fail "tag '$VERSION' is not valid"
[[ $DIGEST =~ ^sha256:[0-9a-f]{64}$ ]] || fail "digest '$DIGEST' is not a sha256 digest"

# The role can write every repository of the namespace, so this list is what stops one service from writing another's image.
if [ "$IMAGE" != "$repo" ] && ! jq -e --arg repo "$repo" --arg image "$IMAGE" '.[$repo] // [] | index($image) != null' "$allowed" >/dev/null; then
  fail "$GITHUB_REPOSITORY may not write image '$IMAGE'; add it to .github/actions/ecr-copy/allowed-images.json in reusable-github-actions"
fi

ecr_repo="$owner/$IMAGE"
source_ref="ghcr.io/$owner/$IMAGE@$DIGEST"
target_ref="$REGISTRY/$ecr_repo:$VERSION"

digest_in_ecr() {
  local err rc=0 out
  err=$(mktemp)
  out=$(aws ecr describe-images --repository-name "$ecr_repo" --image-ids "imageTag=$VERSION" \
    --query 'imageDetails[0].imageDigest' --output text 2>"$err") || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "$out"
  elif ! grep -q 'ImageNotFoundException' "$err"; then
    cat "$err" >&2
    return "$rc"
  fi
}

current=$(digest_in_ecr)
if [ -n "$current" ]; then
  [ "$current" = "$DIGEST" ] || fail "$target_ref already holds $current, not $DIGEST; tags are immutable, so a rerun cannot replace it"
  echo "$target_ref already holds $DIGEST"
  exit 0
fi

# Without --prefer-index=false a single-manifest image is wrapped in a new index and its digest changes.
docker buildx imagetools create --prefer-index=false --tag "$target_ref" "$source_ref"

copied=$(digest_in_ecr)
[ "$copied" = "$DIGEST" ] || fail "$target_ref holds '$copied' after the copy, expected $DIGEST"
echo "$target_ref holds $DIGEST"
