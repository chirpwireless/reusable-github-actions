#!/usr/bin/env bash
# Reads image:tag@digest only from push runs of the trusted branch on a commit of that branch: such a run executed reviewed workflow files.
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
  heads=$(gh api "repos/$REPO/git/matching-refs/heads/ma" --jq '.[].ref') || die "cannot list the branches of $REPO"
  if grep -qxF refs/heads/main <<< "$heads"; then branch=main
  elif grep -qxF refs/heads/master <<< "$heads"; then branch=master
  else die "$REPO has neither main nor master"; fi
else
  branch=$(gh api "repos/$REPO" --jq .default_branch) || die "cannot read the default branch of $REPO"
fi
[[ $branch =~ ^[A-Za-z0-9._/-]+$ ]] || die "unexpected branch name '$branch'"
# A run of a tag push reports the tag name as its branch.
tags=$(gh api "repos/$REPO/git/matching-refs/tags/$branch" --jq '.[].ref') || die "cannot list the tags of $REPO"
! grep -qxF "refs/tags/$branch" <<< "$tags" || die "a tag named $branch exists: runs of $branch cannot be told from runs of the tag"
status=$(gh api "repos/$REPO/compare/$(jq -rn --arg b "$branch" '$b|@uri')...$SHA" --jq .status) || die "cannot compare $SHA with $branch"
case $status in
  identical|behind) ;;
  *) die "$SHA is not on $branch ($status): image digests are trusted only from commits on $branch" ;;
esac

# A run of a tag that was deleted also reports the branch: the commit must have been the head of a push or merge to the branch itself.
pushed=$(SHA=$SHA BRANCH=$branch gh api "repos/$REPO/activity?ref=$(jq -rn --arg b "refs/heads/$branch" '$b|@uri')&time_period=quarter&per_page=100" --paginate \
  --jq '.[] | select(.ref == "refs/heads/" + env.BRANCH and .after == env.SHA and (.activity_type == "push" or .activity_type == "force_push" or .activity_type == "pr_merge" or .activity_type == "merge_queue_merge")) | .after') \
  || die "cannot read the push activity of $branch"
[ -n "$pushed" ] || die "$SHA was not the head of a push or merge to $branch in the last 90 days"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# Only runs of the trusted branch itself: an intermediate commit of a merged branch is on it, but its push run executed that branch's files.
runs=$(SHA=$SHA REPO=$REPO BRANCH=$branch gh api "repos/$REPO/actions/runs?head_sha=$SHA&event=push&status=success&per_page=100" \
  --jq '.workflow_runs[] | select(.event == "push" and .conclusion == "success" and .head_sha == env.SHA and .head_branch == env.BRANCH and .repository.full_name == env.REPO and .head_repository.full_name == env.REPO) | .id')
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

LC_ALL=C sort -u "$T/pins" -o "$T/pins"
[ -s "$T/pins" ] || die "no successful push run of $SHA on $branch recorded image digests"
dup=$(sed 's/@sha256:.*//' "$T/pins" | LC_ALL=C uniq -d)
[ -z "$dup" ] || die "push runs of $SHA recorded different digests for: $(echo $dup)"

delim="PINS_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
{ echo "sha=$SHA"; echo "pins<<$delim"; cat "$T/pins"; echo "$delim"; } >> "$GITHUB_OUTPUT"
{ echo "Trusted image digests of $SHA (on $branch):"; sed 's/^/- /' "$T/pins"; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
