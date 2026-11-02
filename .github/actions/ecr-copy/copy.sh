#!/usr/bin/env bash
set -euo pipefail

: "${IMAGE:?}" "${VERSION:?}" "${DIGEST:?}" "${REGISTRY:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_REF:?}"

owner=${GITHUB_REPOSITORY%%/*}

fail() {
  echo "::error::$1"
  exit 1
}

[[ $IMAGE =~ ^[a-z0-9][a-z0-9._/-]*$ ]] || fail "image name '$IMAGE' is not valid"
[[ $VERSION =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] || fail "tag '$VERSION' is not valid"
[[ $DIGEST =~ ^sha256:[0-9a-f]{64}$ ]] || fail "digest '$DIGEST' is not a sha256 digest"

# Tags are immutable and production takes only main-form tags, so another branch must not be able to write one.
case $GITHUB_REF in
  refs/heads/main | refs/heads/master) ;;
  refs/heads/?*)
    branch=${GITHUB_REF#refs/heads/}
    suffix=${branch//[^a-zA-Z0-9]/-}
    [[ $VERSION == *-"$suffix" ]] || fail "a build of $branch may only write tags ending in -$suffix, not '$VERSION'"
    ;;
  *) fail "$GITHUB_REF is not a branch" ;;
esac

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
