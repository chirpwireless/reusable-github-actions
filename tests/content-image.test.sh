#!/usr/bin/env bash
# Tests of the content tag, registry and digest scripts with a stub docker; run from the repository root.
set -uo pipefail
ROOT=$(pwd)
A=$ROOT/.github/actions
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
D1=sha256:$(printf '1%.0s' {1..64}); D2=sha256:$(printf '2%.0s' {1..64})

repo() {  # a fresh repository with three input files and a Dockerfile
  rm -rf "$T/r"; mkdir -p "$T/r/sub"; cd "$T/r"
  printf a > a.txt; printf b > sub/b.txt; printf c > c.txt; printf 'FROM scratch\n' > Dockerfile
}
tag() {  # tag <inputs command>; prints the tag, exit code of the script
  (cd "$T/r" && CONTENT_INPUTS_CMD=$1 DOCKERFILE=${DF:-Dockerfile} BUILDKIT_IMAGE=${BK:-moby/buildkit:v1@sha256:x} \
    RUNNER_TEMP=$T "$A/content-tag/content-tag.sh" 2> "$T/err")
}

repo
t1=$(tag "printf '%s\n' a.txt sub/b.txt"); rc=$?
[ $rc -eq 0 ] && [[ $t1 =~ ^c-[0-9a-f]{16}$ ]] && ok "tag format" || bad "tag format rc=$rc '$t1' $(cat "$T/err")"
[ "$(tag "printf '%s\n' sub/b.txt ./a.txt a.txt")" = "$t1" ] && ok "order, ./ prefix and repeats do not change the tag" || bad "normalisation"
printf x >> c.txt; [ "$(tag "printf '%s\n' a.txt sub/b.txt")" = "$t1" ] && ok "a file outside the list keeps the tag" || bad "outside file changed the tag"
printf x >> a.txt; [ "$(tag "printf '%s\n' a.txt sub/b.txt")" != "$t1" ] && ok "a listed file changes the tag" || bad "listed file kept the tag"
repo; printf 'RUN x\n' >> Dockerfile; [ "$(tag "printf '%s\n' a.txt sub/b.txt")" != "$t1" ] && ok "the Dockerfile is an input" || bad "Dockerfile not an input"
repo; [ "$(BK=moby/buildkit:v2@sha256:y tag "printf '%s\n' a.txt sub/b.txt")" != "$t1" ] && ok "the BuildKit image is an input" || bad "BuildKit not an input"

repo; ln -s a.txt link.txt; ln -s .. sub/up; mkdir dir
for case in "absolute|printf '%s\n' $T/r/a.txt" "missing|echo nope.txt" "directory|echo dir" "symlink|echo link.txt" \
            "outside|echo ../x.txt" "through a symlinked directory|echo sub/up/r/a.txt" "carriage return|printf 'a.txt\r\n'" \
            "command fails|echo a.txt; false" "no output|true" "only blank lines|printf '\n\n'"; do
  name=${case%%|*}; cmd=${case#*|}
  [ "$name" = outside ] && printf x > "$T/x.txt"
  out=$(tag "$cmd"); rc=$?
  [ $rc -ne 0 ] && [ -z "$out" ] && grep -q '::error::' "$T/err" && ok "refused: $name" || bad "not refused: $name rc=$rc out='$out'"
done
(cd "$T/r" && CONTENT_INPUTS_CMD='echo a.txt' DOCKERFILE=Dockerfile BUILDKIT_IMAGE= "$A/content-tag/content-tag.sh" >/dev/null 2>&1) \
  && bad "empty BuildKit image accepted" || ok "refused: empty BuildKit image"

mkdir -p "$T/bin"; cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$STUB" in
  found) printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"digest":"%s"}}' "$D1" ;;
  index) printf '{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}' ;;
  noconfig) printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{}}' ;;
  notfound) echo "ERROR: ghcr.io/o/i:t: not found" >&2; exit 1 ;;
  denied) echo "ERROR: unexpected status 403 Forbidden" >&2; exit 1 ;;
esac
STUB
chmod +x "$T/bin/docker"
reg() { STUB=$1 D1=$D1 PATH="$T/bin:$PATH" RUNNER_TEMP=$T "$A/content-image-publish/registry-config.sh" ghcr.io/o/i:t 2>&1; }
[ "$(reg found)" = "$D1" ] && ok "registry: config digest of an existing tag" || bad "registry found: $(reg found)"
[ "$(reg notfound)" = absent ] && ok "registry: 404 means absent" || bad "registry notfound"
for s in index noconfig denied; do reg $s >/dev/null && bad "registry accepted: $s" || ok "registry refused: $s"; done

same() { "$A/content-image-publish/same-config.sh" "$@" > "$T/out" 2>&1; }
same c-1 "$D1" "$D1" && grep -q 'pushed=false' "$T/out" && ok "same config, not pushed" || bad "same config"
same c-1 "$D1" "$D1" "$D1" && grep -q 'pushed=true' "$T/out" && ok "same config, pushed" || bad "same config pushed"
same c-1 "$D1" "$D2" && bad "different registry config accepted" || ok "refused: registry differs from the build"
same c-1 "$D1" "$D1" "$D2" && bad "different pushed config accepted" || ok "refused: pushed image differs from the checked build"
same c-1 "$D1" absent && bad "absent accepted as a digest" || ok "refused: not a digest"

dig() { METADATA=$1 "$A/content-image-build/config-digest.sh" 2>/dev/null; }
[ "$(dig "{\"containerimage.config.digest\":\"$D1\"}")" = "$D1" ] && ok "build metadata digest" || bad "build metadata digest"
dig '{}' >/dev/null && bad "missing digest accepted" || ok "refused: no digest in the build metadata"
dig '{"containerimage.config.digest":"sha256:abc"}' >/dev/null && bad "short digest accepted" || ok "refused: malformed digest"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
