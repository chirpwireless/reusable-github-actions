#!/usr/bin/env bash
# Prints the content tag of an image: c- and 16 hex of the SHA-256 over the sorted "<path>\t<sha256>" list of its inputs.
# Env: CONTENT_INPUTS_CMD (prints input paths from the repository root), DOCKERFILE, BUILDKIT_IMAGE.
set -euo pipefail
# Settings of content-image-build and content-image-publish that change image bytes; edit together with them.
RECIPE='platforms=linux/amd64 SOURCE_DATE_EPOCH=0 rewrite-timestamp no-cache no-provenance no-sbom'

fail() { echo "::error::$*" >&2; exit 1; }

[ -n "${CONTENT_INPUTS_CMD:-}" ] || fail "content_inputs_cmd is required for tag_mode content"
[ -n "${DOCKERFILE:-}" ] || fail "dockerfile is empty"
[ -n "${BUILDKIT_IMAGE:-}" ] || fail "the BuildKit image is not set"

work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/content-tag.XXXXXX")
trap 'rm -rf "$work"' EXIT
root=$(realpath -e -- .)

if ! bash -c "set -euo pipefail; $CONTENT_INPUTS_CMD" > "$work/raw"; then
  fail "content_inputs_cmd failed"
fi
normalise() {
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *$'\r'*) fail "carriage return in an input path" ;;
      /*) fail "absolute path in the inputs: $line" ;;
    esac
    line=${line#./}
    case "/$line/" in
      */./*|*/../*|*//*) fail "not a normalised relative path: $line" ;;
    esac
    printf '%s\n' "$line"
  done
}
normalise < "$work/raw" > "$work/paths"
[ -s "$work/paths" ] || fail "content_inputs_cmd printed no paths"
printf '%s\n' "$DOCKERFILE" | normalise >> "$work/paths"
LC_ALL=C sort -u "$work/paths" -o "$work/paths"

while IFS= read -r path; do
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    fail "not a regular file: $path"
  fi
  real=$(realpath -e -- "$path")
  case "$real" in
    "$root"/*) ;;
    *) fail "path outside the repository: $path" ;;
  esac
  sum=$(sha256sum < "$path")
  printf '%s\t%s\n' "$path" "${sum%% *}"
done < "$work/paths" > "$work/list"
printf 'buildkit\t%s\nrecipe\t%s\n' "$BUILDKIT_IMAGE" "$RECIPE" >> "$work/list"
LC_ALL=C sort "$work/list" -o "$work/list"

echo "Content inputs:" >&2
cat "$work/list" >&2
hash=$(sha256sum < "$work/list")
echo "c-${hash:0:16}"
