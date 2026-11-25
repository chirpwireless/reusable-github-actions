#!/usr/bin/env bash
# Runs the step of prod-deploy-gate.yml with a stub gh on allowed and refused prod deploys; run from the repository root.
set -uo pipefail
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
python3 -c '
import sys, yaml
wf = yaml.safe_load(open(".github/workflows/prod-deploy-gate.yml"))
step = wf["jobs"]["gate"]["steps"][0]
print(step["run"], end="")
print(step["env"]["DEPLOYERS"], file=sys.stderr)
' > "$T/step.sh" 2> "$T/deployers" || { echo "FAIL the gate step is not found"; exit 1; }
DEPLOYERS=$(cat "$T/deployers")

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Stub: users/<login> -> id; branches/<b> -> exists if listed; compare/<base>...<sha> -> status by the commit's place.
case "$2" in
  users/*) login=${2#users/}; case "${login,,}" in wirelesstim) echo 173720956 ;; vladimiryarovoy91) echo 186682877 ;; bearil) echo 6340083 ;; impostor) echo 999 ;; outsider) echo 4242 ;; *) exit 1 ;; esac ;;
  repos/o/r/branches/*) b=${2##*/}; case " $STUB_BRANCHES " in *" $b "*) exit 0 ;; *) exit 1 ;; esac ;;
  repos/o/r/compare/*) echo "$2" > "$STUB_DIR/compared"; sha=${2##*...}
    case "$sha" in "$TIP") echo identical ;; "$OLD") echo behind ;; "$UNMERGED") echo ahead ;; "$SIDE") echo diverged ;; *) exit 1 ;; esac ;;
  *) echo "stub gh: unexpected $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$T/bin/gh"
TIP=$(printf 'a%.0s' $(seq 40)); OLD=$(printf 'b%.0s' $(seq 40)); UNMERGED=$(printf 'c%.0s' $(seq 40)); SIDE=$(printf 'd%.0s' $(seq 40))
export TIP OLD UNMERGED SIDE STUB_DIR=$T

# gate <expect pass|fail> <name> [VAR=value...]: runs the step with defaults overridden by the given variables.
gate() { local want=$1 name=$2; shift 2; : > "$T/out"
  env -i PATH="$T/bin:/usr/bin:/bin" STUB_DIR="$T" TIP="$TIP" OLD="$OLD" UNMERGED="$UNMERGED" SIDE="$SIDE" \
    DEPLOYERS="$DEPLOYERS" IS_PROD=true ENVIRONMENT=prod VERSION="$TIP" ACTOR=wirelesstim EVENT=workflow_dispatch \
    REF=refs/heads/main REPO=o/r GH_TOKEN=x STUB_BRANCHES="main develop" GITHUB_OUTPUT="$T/out" "$@" \
    bash "$T/step.sh" > "$T/log" 2>&1
  local rc=$?
  if [ "$want" = pass ] && [ $rc -eq 0 ]; then ok "passes: $name"
  elif [ "$want" = fail ] && [ $rc -ne 0 ] && ! grep -qx 'prod=true' "$T/out"; then ok "refused: $name"
  else bad "$name (rc $rc)"; sed 's/^/     /' "$T/log"; fi; }

gate pass "Tim deploys the tip of main"
gate pass "Vladimir deploys to kiloiot-prod" ACTOR=VladimirYarovoy91 ENVIRONMENT=kiloiot-prod
gate pass "login in another letter case" ACTOR=vladimiryarovoy91
gate pass "an older commit of main (rollback)" VERSION="$OLD"
gate pass "fleet-prod" ENVIRONMENT=fleet-prod
gate pass "repository on master" STUB_BRANCHES="master" REF=refs/heads/master
gate pass "the owner Bearil" ACTOR=Bearil
gate fail "an organization member not on the list" ACTOR=outsider
gate fail "a renamed account reusing a listed login" ACTOR=impostor DEPLOYERS="impostor:1 $DEPLOYERS"
gate fail "empty actor" ACTOR=
gate fail "a commit not merged into main" VERSION="$UNMERGED"
gate fail "a commit on a side branch" VERSION="$SIDE"
gate fail "an unknown commit" VERSION=$(printf 'e%.0s' $(seq 40))
gate fail "short SHA" VERSION=aaaaaaa
gate fail "branch name as version" VERSION=main
gate fail "started by a push" EVENT=push
gate fail "started by workflow_run" EVENT=workflow_run
gate fail "run from a feature branch" REF=refs/heads/feature
gate fail "run from develop" REF=refs/heads/develop
gate fail "repository on master, run from main" STUB_BRANCHES="master" REF=refs/heads/main
gate fail "upper-case prod name" ENVIRONMENT=PROD

# Non-prod environments pass for anyone and say prod=false.
env -i PATH="$T/bin:/usr/bin:/bin" DEPLOYERS="$DEPLOYERS" IS_PROD=false ENVIRONMENT=dev VERSION= ACTOR=Bearil EVENT=workflow_run \
  REF=refs/heads/develop REPO=o/r GH_TOKEN=x GITHUB_OUTPUT="$T/out" bash "$T/step.sh" > "$T/log" 2>&1 \
  && grep -qx 'prod=false' "$T/out" && ok "dev passes for anyone, prod=false" || bad "dev"
# The deployers output is the lower-case login list the deploy job re-checks on re-runs.
grep -qx 'deployers=\["wirelesstim","vladimiryarovoy91","bearil"\]' "$T/out" && ok "deployers output" || { bad "deployers output"; cat "$T/out"; }
# The compare goes from main to the version, so "behind" means the version is on main.
gate pass "compare direction" VERSION="$OLD" && grep -qx "repos/o/r/compare/main...$OLD" "$T/compared" && ok "compared main...version" || bad "compare direction"

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
