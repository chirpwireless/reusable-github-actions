#!/usr/bin/env bash
# Reads image:tag@digest only from push runs of a commit that is on the trusted branch: such a run executed reviewed workflow files.
set -euo pipefail
: "${GITHUB_REPOSITORY:?}" "${GITHUB_OUTPUT:?}" "${GIT_REF:?git-ref is empty}"
REPO=$GITHUB_REPOSITORY
owner=${GITHUB_REPOSITORY_OWNER:-${REPO%%/*}}; owner=${owner,,}
PIN="^ghcr\\.io/${owner}/[a-z0-9][a-z0-9._/-]{0,127}:[A-Za-z0-9_][A-Za-z0-9._-]{0,127}@sha256:[0-9a-f]{64}$"
die() { echo "::error::$1"; exit 1; }

ref=$(jq -rn --arg r "$GIT_REF" '$r|@uri')
SHA=$(gh api "repos/$REPO/commits/$ref" --jq .sha) || die "cannot resolve '$GIT_REF' to a commit"
[[ $SHA =~ ^[0-9a-f]{40}$ ]] || die "'$GIT_REF' resolved to '$SHA', not a commit"

if [ "${PRODUCTION:-false}" = true ]; then
  branch=main
  gh api "repos/$REPO/branches/main" --silent 2>/dev/null || branch=master
else
  branch=$(gh api "repos/$REPO" --jq .default_branch)
fi
[[ $branch =~ ^[A-Za-z0-9._/-]+$ ]] || die "unexpected branch name '$branch'"
status=$(gh api "repos/$REPO/compare/$(jq -rn --arg b "$branch" '$b|@uri')...$SHA" --jq .status) || die "cannot compare $SHA with $branch"
case $status in
  identical|behind) ;;
  *) die "$SHA is not on $branch ($status): image digests are trusted only from commits on $branch" ;;
esac

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
runs=$(SHA=$SHA REPO=$REPO gh api "repos/$REPO/actions/runs?head_sha=$SHA&event=push&status=success&per_page=100" \
  --jq '.workflow_runs[] | select(.event == "push" and .conclusion == "success" and .head_sha == env.SHA and .repository.full_name == env.REPO and .head_repository.full_name == env.REPO) | .id')
: > "$T/pins"
for id in $runs; do
  [[ $id =~ ^[0-9]+$ ]] || die "unexpected run id '$id'"
  names=$(gh api "repos/$REPO/actions/runs/$id/artifacts?per_page=100" --jq '.artifacts[] | select(.expired | not) | .name | select(startswith("image-digest-"))')
  [ -n "$names" ] || continue
  gh run download "$id" -R "$REPO" -p 'image-digest-*' -D "$T/run-$id" > /dev/null || die "cannot download the digests of run $id"
  for name in $names; do
    f="$T/run-$id/$name/pin.txt"
    [ -f "$f" ] && [ ! -L "$f" ] || die "run $id: artifact $name has no pin.txt"
    [ "$(wc -l < "$f")" -eq 1 ] || die "run $id: artifact $name is not one line"
    line=$(cat "$f")
    [[ $line =~ $PIN ]] || die "run $id: artifact $name is not ghcr.io/$owner/<name>:<tag>@sha256:<digest>"
    echo "$line" >> "$T/pins"
  done
done

sort -u "$T/pins" -o "$T/pins"
[ -s "$T/pins" ] || die "no successful push run of $SHA recorded image digests"
dup=$(sed 's/@sha256:.*//' "$T/pins" | uniq -d)
[ -z "$dup" ] || die "push runs of $SHA recorded different digests for: $(echo $dup)"

delim="PINS_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
{ echo "sha=$SHA"; echo "pins<<$delim"; cat "$T/pins"; echo "$delim"; } >> "$GITHUB_OUTPUT"
{ echo "Trusted image digests of $SHA (on $branch):"; sed 's/^/- /' "$T/pins"; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
