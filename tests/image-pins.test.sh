#!/usr/bin/env bash
# Tests the digest record, the trusted digest lookup (with a stub gh) and the post-renderer; run from the repository root.
set -uo pipefail
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
# refused <name> <log file> <expected text> <command...>: the command fails and its log names the reason.
refused() { local n=$1 log=$2 want=$3; shift 3
  if "$@"; then bad "accepted: $n"; elif grep -qF -- "$want" "$log"; then ok "refused: $n"; else bad "wrong reason: $n"; sed 's/^/     /' "$log"; fi; }
D1=sha256:$(printf '1%.0s' $(seq 64)); D2=sha256:$(printf '2%.0s' $(seq 64))
SHA=$(printf 'c%.0s' $(seq 40))
export GITHUB_REPOSITORY=chirpwireless/svc GITHUB_REPOSITORY_OWNER=chirpwireless

# --- record.sh
rec() { : > "$T/out"; IMAGE=$1 TAG=$2 DIGEST=$3 GITHUB_OUTPUT=$T/out RUNNER_TEMP=$T bash .github/actions/image-digest-record/record.sh > "$T/rlog" 2>&1; }
if rec ghcr.io/chirpwireless/svc 1.2.3-abcdef0 "$D1" && grep -qx 'name=image-digest-svc' "$T/out" \
  && [ "$(cat "$(sed -n 's/^path=//p' "$T/out")")" = "ghcr.io/chirpwireless/svc:1.2.3-abcdef0@$D1" ]; then ok "record: one line, artifact named after the image"; else bad "record"; fi
rec ghcr.io/chirpwireless/a/b x "$D1" && grep -qx 'name=image-digest-a_b' "$T/out" && ok "record: nested name" || bad "record nested"
refused "record: other owner" "$T/rlog" "is not ghcr.io/chirpwireless/<name>" rec ghcr.io/other/svc t "$D1"
refused "record: other registry" "$T/rlog" "is not ghcr.io/chirpwireless/<name>" rec docker.io/chirpwireless/svc t "$D1"
refused "record: bad tag" "$T/rlog" "is not a Docker tag" rec ghcr.io/chirpwireless/svc 'a b' "$D1"
refused "record: short digest" "$T/rlog" "is not sha256:<64 hex>" rec ghcr.io/chirpwireless/svc t sha256:abc
refused "record: empty digest" "$T/rlog" "is not sha256:<64 hex>" rec ghcr.io/chirpwireless/svc t ''

# --- trusted-digests.sh with a stub gh
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
F=$STUB_DIR
jqf() { local i; for ((i=1; i<=$#; i++)); do [ "${!i}" = --jq ] && { j=$((i+1)); echo "${!j}"; return; }; done; }
case "$1 $2" in
  "api repos/chirpwireless/svc/commits/"*) [ -z "${STUB_NO_REF:-}" ] || exit 1; echo "$STUB_SHA" ;;
  "api repos/chirpwireless/svc/branches/"*) echo "$2" >> "$F/protection-query"; echo "${STUB_PROTECTED:-true}" ;;
  "api repos/chirpwireless/svc/git/matching-refs/heads/ma") printf '%s\n' $STUB_HEADS | jq -R '{ref: .}' | jq -s . | jq -r "$(jqf "$@")" ;;
  "api repos/chirpwireless/svc/git/matching-refs/tags/"*) printf '%s\n' $STUB_TAGS | jq -R 'select(. != "") | {ref: .}' | jq -s . | jq -r "$(jqf "$@")" ;;
  "api repos/chirpwireless/svc") echo develop ;;
  "api repos/chirpwireless/svc/activity?"*) echo "$2" >> "$F/activity-query"; printf '%s\n' "$STUB_ACT" | jq -R 'select(. != "") | split(" ") | {activity_type: .[0], ref: .[1], after: .[2]}' | jq -s . | jq -r "$(jqf "$@")" ;;
  "api repos/chirpwireless/svc/compare/"*) echo "$2" >> "$F/compared"; echo "$STUB_STATUS" ;;
  "api repos/chirpwireless/svc/actions/runs?"*) echo "$2" >> "$F/runs-query"; jq -r "$(jqf "$@")" "$F/runs.json" ;;
  "api repos/chirpwireless/svc/actions/runs/"*) id=${2#repos/chirpwireless/svc/actions/runs/}; id=${id%%/*}; jq -r "$(jqf "$@")" "$F/artifacts-$id.json" ;;
  "run download") [ "$4 $5 $6 $7 $8" = "-R chirpwireless/svc -p image-digest-* -D" ] || exit 3; dir=${9:?}; mkdir -p "$dir"; cp -RP "$F/dl-$3/." "$dir/" ;;
  *) echo "stub gh: unexpected $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$T/bin/gh"
S=$T/stub; mkdir -p "$S"
run_json() { # id event conclusion head_sha head_branch head_repo ...
  local out='[]' id ev co hs hb rp
  while [ $# -gt 0 ]; do id=$1 ev=$2 co=$3 hs=$4 hb=$5 rp=$6; shift 6
    out=$(jq -c --argjson id "$id" --arg ev "$ev" --arg co "$co" --arg hs "$hs" --arg hb "$hb" --arg rp "$rp" \
      '. + [{id:$id, event:$ev, conclusion:$co, head_sha:$hs, head_branch:$hb, repository:{full_name:"chirpwireless/svc"}, head_repository:{full_name:$rp}}]' <<< "$out"); done
  jq -c '{workflow_runs: .}' <<< "$out" > "$S/runs.json"
}
artifacts() { # id name...
  local id=$1; shift
  printf '%s\n' "$@" | jq -R . | jq -sc '{artifacts: map({name: ., expired: false})}' > "$S/artifacts-$id.json"
  rm -rf "$S/dl-$id"; mkdir -p "$S/dl-$id"
}
pin() { mkdir -p "$S/dl-$1/$2"; printf '%s\n' "$3" > "$S/dl-$1/$2/pin.txt"; }
lookup() { rm -f "$S/compared" "$S/runs-query"; : > "$T/gout"
  local b=main; [ "${PRODUCTION:-true}" = true ] || b=develop; [ "${STUB_HEADS:-}" != refs/heads/master ] || b=master
  PATH=$T/bin:$PATH STUB_DIR=$S STUB_SHA=${STUB_SHA:-$SHA} STUB_STATUS=${STUB_STATUS:-behind} STUB_HEADS=${STUB_HEADS:-refs/heads/main} \
    STUB_ACT=${STUB_ACT-"pr_merge refs/heads/$b ${STUB_SHA:-$SHA}"} \
    STUB_TAGS=${STUB_TAGS:-} GIT_REF=${GIT_REF:-$SHA} PRODUCTION=${PRODUCTION:-true} \
    GITHUB_OUTPUT=$T/gout bash .github/actions/trusted-image-digests/trusted-digests.sh > "$T/glog" 2>&1; }
with() { local cmd=${!#} kv; ( for kv in "${@:1:$#-1}"; do export "$kv"; done; "$cmd" ); }
pins_out() { sed -n '/^pins<</,/^PINS_/p' "$T/gout" | sed '1d;$d'; }
OTHER=$(printf 'd%.0s' $(seq 40))

run_json 11 push success "$SHA" main chirpwireless/svc 12 pull_request success "$SHA" main chirpwireless/svc 13 push success "$SHA" main fork/svc \
  14 push failure "$SHA" main chirpwireless/svc 15 push success "$OTHER" main chirpwireless/svc 17 push success "$SHA" feature-x chirpwireless/svc
artifacts 11 image-digest-svc image-digest-svc-kg; pin 11 image-digest-svc "ghcr.io/chirpwireless/svc:1.2.3-ccccccc@$D1"; pin 11 image-digest-svc-kg "ghcr.io/chirpwireless/svc-kg:$SHA@$D2"
for id in 12 13 14 15 17; do artifacts $id image-digest-svc; pin $id image-digest-svc "ghcr.io/chirpwireless/svc:1.2.3-ccccccc@$D2"; done
if lookup && [ "$(pins_out)" = "$(printf '%s\n' "ghcr.io/chirpwireless/svc-kg:$SHA@$D2" "ghcr.io/chirpwireless/svc:1.2.3-ccccccc@$D1" | LC_ALL=C sort)" ] \
  && grep -qx "sha=$SHA" "$T/gout" && grep -q "compare/main...$SHA" "$S/compared" && grep -q 'event=push' "$S/runs-query"; then
  ok "lookup: only the successful push run of main on this commit in this repository"; else bad "lookup"; cat "$T/glog"; fi
run_json 17 push success "$SHA" feature-x chirpwireless/svc
refused "a push run of another branch on a commit now on main" "$T/glog" "on main recorded image digests" lookup
run_json 11 push success "$SHA" master chirpwireless/svc
STUB_HEADS=refs/heads/master lookup && grep -q "compare/master...$SHA" "$S/compared" && ok "lookup: master when main is absent" || bad "master"
refused "neither main nor master" "$T/glog" "has neither main nor master" with STUB_HEADS=refs/heads/maintenance lookup
run_json 11 push success "$SHA" develop chirpwireless/svc
PRODUCTION=false lookup && grep -q "compare/develop...$SHA" "$S/compared" && ok "lookup: dev trusts runs of the default branch" || bad "default branch"
refused "dev: commit not on the default branch" "$T/glog" "is not on develop" with PRODUCTION=false STUB_STATUS=ahead lookup
refused "dev: a tag named like the default branch" "$T/glog" "a tag named develop exists" with PRODUCTION=false STUB_TAGS=refs/tags/develop lookup
run_json 11 push success "$SHA" main chirpwireless/svc
refused "a tag named main" "$T/glog" "a tag named main exists" with STUB_TAGS=refs/tags/main lookup
STUB_TAGS=refs/tags/main-1 lookup && ok "lookup: a tag that only starts with main is fine" || bad "tag prefix"
refused "commit not on main" "$T/glog" "is not on main (ahead)" with STUB_STATUS=ahead lookup
[ ! -s "$T/gout" ] && ok "refused lookup writes no output" || bad "refused lookup wrote output"
refused "a commit never pushed or merged to main (a deleted tag)" "$T/glog" "was not the head of a push or merge to main" with STUB_ACT= lookup
refused "a push of the commit to another branch" "$T/glog" "was not the head of a push or merge to main" with "STUB_ACT=push refs/heads/feature-x $SHA" lookup
refused "the activity of main has other commits only" "$T/glog" "was not the head of a push or merge to main" with "STUB_ACT=pr_merge refs/heads/main $OTHER" lookup
refused "production on an unprotected branch" "$T/glog" "main is not protected" with STUB_PROTECTED=false lookup
refused "production on an unprotected master" "$T/glog" "master is not protected" with STUB_HEADS=refs/heads/master STUB_PROTECTED=false lookup
rm -f "$S/protection-query"; PRODUCTION=false lookup; [ ! -e "$S/protection-query" ] && ok "dev does not require a protected branch" || bad "dev protection"
refused "a branch creation is not a push" "$T/glog" "was not the head of a push or merge to main" with "STUB_ACT=branch_creation refs/heads/main $SHA" lookup
with "STUB_ACT=push refs/heads/main $SHA" lookup && grep -q 'ref=refs%2Fheads%2Fmain' "$S/activity-query" && ok "lookup: a direct push to main counts" || bad "direct push"
refused "diverged commit" "$T/glog" "is not on main (diverged)" with STUB_STATUS=diverged lookup
refused "unknown ref" "$T/glog" "cannot resolve" with STUB_NO_REF=1 lookup
refused "resolved value is not a commit" "$T/glog" "not a commit" with STUB_SHA=abc lookup
artifacts 11 image-digest-svc; pin 11 image-digest-svc "ghcr.io/chirpwireless/svc:1.2.3-ccccccc@$D1"; artifacts 16 image-digest-svc; pin 16 image-digest-svc "ghcr.io/chirpwireless/svc:1.2.3-ccccccc@$D2"
run_json 11 push success "$SHA" main chirpwireless/svc 16 push success "$SHA" main chirpwireless/svc
refused "two digests for one tag" "$T/glog" "different digests" lookup
run_json 11 push success "$SHA" main chirpwireless/svc
for line in "ghcr.io/other/svc:t@$D1" "ghcr.io/chirpwireless/svc:t" "ghcr.io/chirpwireless/svc:t@$D1 x" "ghcr.io/chirpwireless/svc:t@sha256:12"; do
  artifacts 11 image-digest-svc; pin 11 image-digest-svc "$line"
  refused "pin $line" "$T/glog" "is not ghcr.io/chirpwireless" lookup
done
artifacts 11 image-digest-svc; pin 11 image-digest-svc "$(printf 'ghcr.io/chirpwireless/svc:t@%s\nghcr.io/chirpwireless/svc:u@%s' "$D1" "$D1")"
refused "artifact of two lines" "$T/glog" "is not one line" lookup
artifacts 11 image-digest-svc; mkdir -p "$S/dl-11/image-digest-svc"
refused "artifact without pin.txt" "$T/glog" "has no pin.txt" lookup
artifacts 11 image-digest-svc; mkdir -p "$S/dl-11/image-digest-svc"; printf '%s\n' "ghcr.io/chirpwireless/svc:t@$D1" > "$T/real"; ln -s "$T/real" "$S/dl-11/image-digest-svc/pin.txt"
refused "pin.txt that is a link" "$T/glog" "has no pin.txt" lookup
artifacts 11 other-artifact
refused "no digests recorded" "$T/glog" "recorded image digests" lookup

# --- pin-images.py
R=.github/actions/image-pins/pin-images.py
printf '%s\n' "ghcr.io/chirpwireless/svc:1.2.3-ccccccc@$D1" "ghcr.io/chirpwireless/svc-kg:$SHA@$D2" > "$T/pins"
render() { IMAGE_PINS_OWNER=chirpwireless IMAGE_PINS_FILE=$T/pins python3 "$R" "$@" > "$T/rout" 2> "$T/rerr"; }
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
render_of() { printf '%s\n' "$1" | render; local rc=$?; [ -s "$T/rout" ] && { echo "printed output" >> "$T/rerr"; return 0; }; return $rc; }
refused "render: unknown tag" "$T/rerr" "no trusted digest for ghcr.io/chirpwireless/svc:9.9.9-ccccccc" render_of 'image: ghcr.io/chirpwireless/svc:9.9.9-ccccccc'
refused "render: unknown image" "$T/rerr" "no trusted digest for ghcr.io/chirpwireless/other:1" render_of 'image: ghcr.io/chirpwireless/other:1'
refused "render: env value" "$T/rerr" "is not an image pinned by digest" render_of 'env: [{name: X, value: "ghcr.io/chirpwireless/svc:1.2.3-ccccccc"}]'
refused "render: flow style" "$T/rerr" "is not an image pinned by digest" render_of '{image: ghcr.io/chirpwireless/svc:1.2.3-ccccccc}'
refused "render: registry prefix" "$T/rerr" "localhost:7439/ghcr.io/chirpwireless/svc:1.2.3-ccccccc is not an image pinned" render_of 'image: localhost:7439/ghcr.io/chirpwireless/svc:1.2.3-ccccccc'
refused "render: upper case" "$T/rerr" "no trusted digest for GHCR.IO/chirpwireless/svc:1.2.3-ccccccc" render_of 'image: GHCR.IO/chirpwireless/svc:1.2.3-ccccccc'
refused "render: after =" "$T/rerr" "ghcr.io/chirpwireless/svc-kg:latest is not an image pinned" render_of 'value: KG=ghcr.io/chirpwireless/svc-kg:latest'
refused "render: no tag" "$T/rerr" "no trusted digest for ghcr.io/chirpwireless/svc" render_of 'image: ghcr.io/chirpwireless/svc'
printf 'bad line\n' > "$T/pins.bad"
refused "a bad pins file" "$T/rerr" "bad pin line" sh -c "echo 'image: x' | IMAGE_PINS_OWNER=chirpwireless IMAGE_PINS_FILE=$T/pins.bad python3 $R > /dev/null 2> $T/rerr"
printf '%s\n' "ghcr.io/chirpwireless/svc:t@$D1" "ghcr.io/chirpwireless/svc:t@$D2" > "$T/pins.two"
refused "two digests in the pins file" "$T/rerr" "two digests for ghcr.io/chirpwireless/svc:t" sh -c "echo 'image: x' | IMAGE_PINS_OWNER=chirpwireless IMAGE_PINS_FILE=$T/pins.two python3 $R > /dev/null 2> $T/rerr"
refused "no owner" "$T/rerr" "are required" sh -c "echo 'image: x' | IMAGE_PINS_OWNER= IMAGE_PINS_FILE=$T/pins python3 $R > /dev/null 2> $T/rerr"

# --check: the whole template output, hooks included
check_of() { printf '%s\n' "$1" | render --check; local rc=$?; [ -s "$T/rout" ] && { echo "printed output" >> "$T/rerr"; return 0; }; return $rc; }
check_of "image: \"ghcr.io/chirpwireless/svc:1.2.3-ccccccc@$D1\"
image: ghcr.io/chirpwireless/brewctl:0.6.0@$D2
image: liquibase/liquibase:4.28.0-alpine" && ok "check: pinned, pinned in values and foreign pass" || { bad "check good"; cat "$T/rerr"; }
refused "check: hook by tag" "$T/rerr" "ghcr.io/chirpwireless/migrations:1 is not an image pinned" check_of 'image: ghcr.io/chirpwireless/migrations:1'
refused "check: another digest for a recorded tag" "$T/rerr" "is not the trusted digest of ghcr.io/chirpwireless/svc:1.2.3-ccccccc" check_of "image: ghcr.io/chirpwireless/svc:1.2.3-ccccccc@$D2"

# --- helm: a hook never reaches the post-renderer, so only --check over the template output stops it
if command -v helm > /dev/null; then
  mkdir -p "$T/c/templates"
  printf 'apiVersion: v2\nname: c\nversion: 0.1.0\n' > "$T/c/Chart.yaml"
  printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: p\nspec:\n  containers:\n    - name: p\n      image: ghcr.io/chirpwireless/svc:1.2.3-ccccccc\n' > "$T/c/templates/pod.yaml"
  printf 'apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: h\n  annotations:\n    helm.sh/hook: pre-upgrade\nspec:\n  template:\n    spec:\n      containers:\n        - name: h\n          image: ghcr.io/chirpwireless/hook:1\n' > "$T/c/templates/hook.yaml"
  install -m 0755 "$R" "$T/pin-images"
  export IMAGE_PINS_OWNER=chirpwireless IMAGE_PINS_FILE=$T/pins
  if helm template r "$T/c" --post-renderer "$T/pin-images" > "$T/h.yaml" 2> "$T/herr" \
    && grep -qF "image: ghcr.io/chirpwireless/svc:1.2.3-ccccccc@$D1" "$T/h.yaml" && grep -qF 'image: ghcr.io/chirpwireless/hook:1' "$T/h.yaml"; then
    ok "helm: the post-renderer pins the pod and does not see the hook"; else bad "helm render"; cat "$T/herr"; fi
  refused "helm: --check over the template output stops the hook" "$T/rerr" "ghcr.io/chirpwireless/hook:1 is not an image pinned" sh -c "\"$T/pin-images\" --check < \"$T/h.yaml\" 2> \"$T/rerr\""
  unset IMAGE_PINS_OWNER IMAGE_PINS_FILE
else
  bad "helm is not installed"
fi

# --- the deploy job checks it checked out the commit whose digests were read
python3 -c '
import yaml
steps = yaml.safe_load(open(".github/workflows/deploy-helmfile.yml"))["jobs"]["deploy"]["steps"]
print(next(s["run"] for s in steps if s.get("name") == "The checked-out commit is the one whose digests were read"), end="")
' > "$T/shastep.sh"
mkdir -p "$T/gitbin"; printf '#!/bin/sh\necho "$FAKE_HEAD"\n' > "$T/gitbin/git"; chmod +x "$T/gitbin/git"
PATH=$T/gitbin:$PATH FAKE_HEAD=$SHA SHA=$SHA bash -e "$T/shastep.sh" > /dev/null 2>&1 && ok "deploy: the same commit passes" || bad "deploy same commit"
refused "deploy: another checked-out commit" "$T/slog" "digests are of $SHA" sh -c "PATH=$T/gitbin:\$PATH FAKE_HEAD=$OTHER SHA=$SHA bash -e $T/shastep.sh > $T/slog 2>&1"

# --- the deploy step: check before apply on the pinned path, plain apply otherwise
python3 -c '
import yaml
steps = yaml.safe_load(open(".github/workflows/deploy-helmfile.yml"))["jobs"]["deploy"]["steps"]
print(next(s["run"] for s in steps if s.get("name") == "Deploy using helmfile"), end="")
' | sed 's/\${{ *inputs\.deploy_dir *}}/./; s/\${{ *inputs\.environment *}}/dev/g; s/\${{ *inputs\.namespace || inputs\.environment *}}/dev/g' > "$T/deploystep.sh"
mkdir -p "$T/hfbin"
printf '#!/bin/sh\necho "helmfile $*" >> "$CALLS"\n[ "$5" = template ] && echo "image: x"\nexit 0\n' > "$T/hfbin/helmfile"
printf '#!/bin/sh\necho "renderer $*" >> "$CALLS"\n[ "$1" = --check ] && [ -n "$CHECK_FAILS" ] && exit 1\ncat\n' > "$T/hfbin/renderer"
chmod +x "$T/hfbin/helmfile" "$T/hfbin/renderer"
deploy_step() { : > "$T/calls"; (cd "$T" && PATH=$T/hfbin:$PATH CALLS=$T/calls RUNNER_TEMP=$T bash -e "$T/deploystep.sh") > "$T/dlog" 2>&1; }
PIN_IMAGES=true IMAGE_PINS_RENDERER=$T/hfbin/renderer deploy_step \
  && [ "$(sed 's/ -e dev -n dev / /' "$T/calls" | tr '\n' '|')" = "helmfile template --post-renderer $T/hfbin/renderer|renderer --check|helmfile apply --post-renderer $T/hfbin/renderer|" ] \
  && ok "deploy step: template, check, then apply with the renderer" || { bad "deploy step pinned"; cat "$T/calls" "$T/dlog"; }
PIN_IMAGES=true IMAGE_PINS_RENDERER=$T/hfbin/renderer CHECK_FAILS=1 deploy_step; rc=$?
[ $rc -ne 0 ] && ! grep -q 'helmfile.* apply' "$T/calls" && ok "deploy step: a failing check stops before apply" || bad "deploy step check failure"
PIN_IMAGES=true deploy_step; rc=$?
[ $rc -ne 0 ] && [ ! -s "$T/calls" ] && ok "deploy step: pinned path without the renderer fails before helmfile" || bad "deploy step no renderer"
PIN_IMAGES=false IMAGE_PINS_RENDERER=$T/hfbin/renderer deploy_step \
  && [ "$(sed 's/ -e dev -n dev / /' "$T/calls")" = "helmfile apply" ] && ok "deploy step: without pinning a plain apply" || { bad "deploy step plain"; cat "$T/calls"; }

# --- wiring
python3 - <<'EOF' && ok "wiring: pin steps gated by pin_images, check before apply, record right after the push, no cache outside pull requests" || bad "wiring"
import yaml
w = yaml.safe_load(open(".github/workflows/deploy-helmfile.yml"))
assert w[True]["workflow_call"]["inputs"]["pin_images"]["default"] is False
fetch = {s.get("id"): s for s in w["jobs"]["fetch_version"]["steps"]}
assert fetch["digests"]["if"] == "${{ inputs.pin_images }}"
deploy = {s.get("name"): s for s in w["jobs"]["deploy"]["steps"]}
assert deploy["Pin images by digest"]["if"] == "${{ inputs.pin_images }}"
assert deploy["The checked-out commit is the one whose digests were read"]["if"] == "${{ inputs.pin_images }}"
step = deploy["Deploy using helmfile"]
assert step["env"]["PIN_IMAGES"] == "${{ inputs.pin_images }}"
run = step["run"]
assert run.index('"$IMAGE_PINS_RENDERER" --check') < run.index('apply --post-renderer "$IMAGE_PINS_RENDERER"')
b = yaml.safe_load(open(".github/workflows/build-go.yml"))["jobs"]["build"]["steps"]
i = next(n for n, s in enumerate(b) if s.get("id") == "push-image")
assert b[i + 1]["uses"].endswith("/image-digest-record@main") and "steps.push-image.outputs.digest" in b[i + 1]["with"]["digest"]
cache = b[i]["with"]
for k in ("cache-from", "cache-to"):
    assert cache[k].startswith("${{ github.event_name == 'pull_request' && format('type=registry,") and cache[k].endswith(") || '' }}"), cache[k]
EOF
echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
