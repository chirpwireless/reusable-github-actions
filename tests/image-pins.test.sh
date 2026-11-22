#!/usr/bin/env bash
# Tests the digest record, the trusted digest lookup (with a stub gh) and the post-renderer; run from the repository root.
set -uo pipefail
ROOT=$PWD
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
D1=sha256:$(printf '1%.0s' $(seq 64)); D2=sha256:$(printf '2%.0s' $(seq 64))
SHA=$(printf 'c%.0s' $(seq 40))
export GITHUB_REPOSITORY=chirpwireless/svc GITHUB_REPOSITORY_OWNER=chirpwireless

# --- record.sh
rec() { : > "$T/out"; IMAGE=$1 TAG=$2 DIGEST=$3 GITHUB_OUTPUT=$T/out RUNNER_TEMP=$T bash .github/actions/image-digest-record/record.sh > /dev/null 2>&1; }
if rec ghcr.io/chirpwireless/svc 1.2.3-abcdef0 "$D1" && grep -qx 'name=image-digest-svc' "$T/out" \
  && [ "$(cat "$(sed -n 's/^path=//p' "$T/out")")" = "ghcr.io/chirpwireless/svc:1.2.3-abcdef0@$D1" ]; then ok "record: one line, artifact named after the image"; else bad "record"; fi
rec ghcr.io/chirpwireless/a/b x "$D1" && grep -qx 'name=image-digest-a_b' "$T/out" && ok "record: nested name" || bad "record nested"
for args in "ghcr.io/other/svc|t|$D1" "docker.io/chirpwireless/svc|t|$D1" "ghcr.io/chirpwireless/svc|a b|$D1" "ghcr.io/chirpwireless/svc|t|sha256:abc" "ghcr.io/chirpwireless/svc|t|"; do
  IFS='|' read -r i t d <<< "$args"
  rec "$i" "$t" "$d" && bad "record accepted $args" || ok "record refused $args"
done

# --- trusted-digests.sh with a stub gh
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
F=$STUB_DIR
jqf() { local i; for ((i=1; i<=$#; i++)); do [ "${!i}" = --jq ] && { j=$((i+1)); echo "${!j}"; return; }; done; }
case "$1 $2" in
  "api repos/chirpwireless/svc/commits/"*) [ -z "${STUB_NO_REF:-}" ] || exit 1; echo "$STUB_SHA" ;;
  "api repos/chirpwireless/svc/branches/main") [ -z "${STUB_NO_MAIN:-}" ] || exit 1 ;;
  "api repos/chirpwireless/svc") echo develop ;;
  "api repos/chirpwireless/svc/compare/"*) echo "$2" >> "$F/compared"; echo "$STUB_STATUS" ;;
  "api repos/chirpwireless/svc/actions/runs?"*) echo "$2" >> "$F/runs-query"; jq -r "$(jqf "$@")" "$F/runs.json" ;;
  "api repos/chirpwireless/svc/actions/runs/"*) id=${2#repos/chirpwireless/svc/actions/runs/}; id=${id%%/*}; jq -r "$(jqf "$@")" "$F/artifacts-$id.json" ;;
  "run download") dir=${9:?}; mkdir -p "$dir"; cp -R "$F/dl-$3/." "$dir/" ;;
  *) echo "stub gh: unexpected $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$T/bin/gh"
S=$T/stub; mkdir -p "$S"
run_json() { # id event conclusion head_sha repo...
  local out='[]' id ev co hs rp
  while [ $# -gt 0 ]; do id=$1 ev=$2 co=$3 hs=$4 rp=$5; shift 5
    out=$(jq -c --argjson id "$id" --arg ev "$ev" --arg co "$co" --arg hs "$hs" --arg rp "$rp" \
      '. + [{id:$id, event:$ev, conclusion:$co, head_sha:$hs, repository:{full_name:"chirpwireless/svc"}, head_repository:{full_name:$rp}}]' <<< "$out"); done
  jq -c '{workflow_runs: .}' <<< "$out" > "$S/runs.json"
}
artifacts() { # id name...
  local id=$1; shift; local n
  printf '%s\n' "$@" | jq -R . | jq -sc '{artifacts: map({name: ., expired: false})}' > "$S/artifacts-$id.json"
  rm -rf "$S/dl-$id"; mkdir -p "$S/dl-$id"
}
pin() { mkdir -p "$S/dl-$1/$2"; printf '%s\n' "$3" > "$S/dl-$1/$2/pin.txt"; }
lookup() { rm -f "$S/compared" "$S/runs-query"; : > "$T/gout"
  PATH=$T/bin:$PATH STUB_DIR=$S STUB_SHA=${STUB_SHA:-$SHA} STUB_STATUS=${STUB_STATUS:-behind} GIT_REF=${GIT_REF:-$SHA} PRODUCTION=${PRODUCTION:-true} \
    GITHUB_OUTPUT=$T/gout bash .github/actions/trusted-image-digests/trusted-digests.sh > "$T/glog" 2>&1; }
pins_out() { sed -n '/^pins<</,/^PINS_/p' "$T/gout" | sed '1d;$d'; }

run_json 11 push success "$SHA" chirpwireless/svc 12 pull_request success "$SHA" chirpwireless/svc 13 push success "$SHA" fork/svc 14 push failure "$SHA" chirpwireless/svc 15 push success "$(printf 'd%.0s' $(seq 40))" chirpwireless/svc
artifacts 11 image-digest-svc image-digest-svc-kg; pin 11 image-digest-svc "ghcr.io/chirpwireless/svc:1.2.3-ccccccc@$D1"; pin 11 image-digest-svc-kg "ghcr.io/chirpwireless/svc-kg:$SHA@$D2"
for id in 12 13 14 15; do artifacts $id image-digest-svc; pin $id image-digest-svc "ghcr.io/chirpwireless/svc:1.2.3-ccccccc@$D2"; done
if lookup && [ "$(pins_out)" = "$(printf '%s\n' "ghcr.io/chirpwireless/svc-kg:$SHA@$D2" "ghcr.io/chirpwireless/svc:1.2.3-ccccccc@$D1" | sort)" ] \
  && grep -qx "sha=$SHA" "$T/gout" && grep -q "compare/main...$SHA" "$S/compared" && grep -q 'event=push' "$S/runs-query"; then
  ok "lookup: only the successful push run of this commit in this repository"; else bad "lookup"; cat "$T/glog"; fi
STUB_NO_MAIN=1 lookup && grep -q "compare/master...$SHA" "$S/compared" && ok "lookup: master when main is absent" || bad "master"
PRODUCTION=false lookup && grep -q "compare/develop...$SHA" "$S/compared" && ok "lookup: dev trusts the default branch" || bad "default branch"
STUB_STATUS=ahead lookup && bad "accepted a commit not on main" || { grep -q 'is not on main' "$T/glog" && [ ! -s "$T/gout" ] && ok "refused: commit not on main" || bad "not on main message"; }
STUB_STATUS=diverged lookup && bad "accepted a diverged commit" || ok "refused: diverged commit"
STUB_NO_REF=1 lookup && bad "accepted an unknown ref" || ok "refused: unknown ref"
STUB_SHA=abc lookup && bad "accepted a bad sha" || ok "refused: resolved value is not a commit"
artifacts 11 image-digest-svc; pin 11 image-digest-svc "ghcr.io/chirpwireless/svc:1.2.3-ccccccc@$D1"; artifacts 16 image-digest-svc; pin 16 image-digest-svc "ghcr.io/chirpwireless/svc:1.2.3-ccccccc@$D2"
run_json 11 push success "$SHA" chirpwireless/svc 16 push success "$SHA" chirpwireless/svc
lookup && bad "accepted two digests for one tag" || { grep -q 'different digests' "$T/glog" && ok "refused: two digests for one tag" || bad "two digests message"; }
run_json 11 push success "$SHA" chirpwireless/svc
for line in "ghcr.io/other/svc:t@$D1" "ghcr.io/chirpwireless/svc:t" "ghcr.io/chirpwireless/svc:t@$D1 x" "ghcr.io/chirpwireless/svc:t@sha256:12"; do
  artifacts 11 image-digest-svc; pin 11 image-digest-svc "$line"
  lookup && bad "accepted pin $line" || { grep -q "is not ghcr.io/chirpwireless" "$T/glog" && ok "refused pin: $line" || bad "pin message: $line"; }
done
artifacts 11 image-digest-svc; pin 11 image-digest-svc "$(printf 'ghcr.io/chirpwireless/svc:t@%s\nghcr.io/chirpwireless/svc:u@%s' "$D1" "$D1")"
lookup && bad "accepted two lines" || { grep -q "is not one line" "$T/glog" && ok "refused: artifact of two lines" || bad "two lines message"; }
artifacts 11 other-artifact
lookup && bad "accepted a run without digests" || { grep -q 'recorded image digests' "$T/glog" && ok "refused: no digests recorded" || bad "no digests message"; }

# --- pin-images.py
R=.github/actions/image-pins/pin-images.py
printf '%s\n' "ghcr.io/chirpwireless/svc:1.2.3-ccccccc@$D1" "ghcr.io/chirpwireless/svc-kg:$SHA@$D2" > "$T/pins"
render() { IMAGE_PINS_OWNER=chirpwireless IMAGE_PINS_FILE=$T/pins python3 "$R" > "$T/rout" 2> "$T/rerr"; }
cat > "$T/m.yaml" <<EOF
spec:
  containers:
    - name: a
      image: "ghcr.io/chirpwireless/svc:1.2.3-ccccccc"
    - image: ghcr.io/chirpwireless/svc-kg:$SHA # comment
    - image: 'ghcr.io/chirpwireless/brewctl:0.6.0@$D2'
    - image: curlimages/curl:8.5.0
EOF
if render < "$T/m.yaml" && grep -qF "image: \"ghcr.io/chirpwireless/svc:1.2.3-ccccccc@$D1\"" "$T/rout" \
  && grep -qF "image: ghcr.io/chirpwireless/svc-kg:$SHA@$D2 # comment" "$T/rout" \
  && grep -qF "image: 'ghcr.io/chirpwireless/brewctl:0.6.0@$D2'" "$T/rout" && grep -qF 'image: curlimages/curl:8.5.0' "$T/rout" \
  && [ "$(wc -l < "$T/rout")" -eq "$(wc -l < "$T/m.yaml")" ]; then ok "render: tags pinned, pinned and foreign images kept"; else bad "render"; cat "$T/rerr"; fi
for m in 'image: ghcr.io/chirpwireless/svc:9.9.9-ccccccc' 'image: ghcr.io/chirpwireless/other:1' \
  'env: [{name: X, value: "ghcr.io/chirpwireless/svc:1.2.3-ccccccc"}]' '{image: ghcr.io/chirpwireless/svc:1.2.3-ccccccc}' \
  'image: localhost:7439/ghcr.io/chirpwireless/svc:1.2.3-ccccccc' 'image: GHCR.IO/chirpwireless/svc:1.2.3-ccccccc' \
  'value: KG=ghcr.io/chirpwireless/svc-kg:latest' 'image: ghcr.io/chirpwireless/svc'; do
  printf '%s\n' "$m" | render && bad "render accepted: $m" || { [ ! -s "$T/rout" ] && ok "render refused: $m" || bad "render printed output: $m"; }
done
printf 'bad line\n' > "$T/pins"; echo 'image: x' | render && bad "accepted a bad pins file" || ok "refused: bad pins file"
printf '%s\n' "ghcr.io/chirpwireless/svc:t@$D1" "ghcr.io/chirpwireless/svc:t@$D2" > "$T/pins"; echo 'image: x' | render && bad "accepted two digests" || ok "refused: two digests for one tag in the pins file"
echo 'image: x' | IMAGE_PINS_OWNER= IMAGE_PINS_FILE=$T/pins python3 "$R" > /dev/null 2>&1 && bad "ran without owner" || ok "refused: no owner"

# --- the workflow passes the renderer only when pinning
python3 - <<'EOF' && ok "deploy: pin steps gated by pin_images, renderer passed to apply" || bad "deploy wiring"
import yaml
w = yaml.safe_load(open(".github/workflows/deploy-helmfile.yml"))
assert w[True]["workflow_call"]["inputs"]["pin_images"]["default"] is False
fetch = {s.get("id"): s for s in w["jobs"]["fetch_version"]["steps"]}
assert fetch["digests"]["if"] == "${{ inputs.pin_images }}"
deploy = {s.get("name"): s for s in w["jobs"]["deploy"]["steps"]}
assert deploy["Pin images by digest"]["if"] == "${{ inputs.pin_images }}"
assert deploy["The checked-out commit is the one whose digests were read"]["if"] == "${{ inputs.pin_images }}"
assert '${IMAGE_PINS_RENDERER:+--post-renderer "$IMAGE_PINS_RENDERER"}' in deploy["Deploy using helmfile"]["run"]
b = yaml.safe_load(open(".github/workflows/build-go.yml"))["jobs"]["build"]["steps"]
i = next(n for n, s in enumerate(b) if s.get("id") == "push-image")
assert b[i + 1]["uses"].endswith("/image-digest-record@main") and "steps.push-image.outputs.digest" in b[i + 1]["with"]["digest"]
EOF
echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
