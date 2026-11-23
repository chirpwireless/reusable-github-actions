#!/usr/bin/env bash
# Runs the "Export the additional versions" step of deploy-helmfile.yml on good and bad input; run from the repository root.
set -uo pipefail
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
python3 -c '
import sys, yaml
steps = yaml.safe_load(open(".github/workflows/deploy-helmfile.yml"))["jobs"]["deploy"]["steps"]
print(next(s["run"] for s in steps if s.get("name") == "Export the additional versions"), end="")
' > "$T/step.sh" || { echo "FAIL the step is not found"; exit 1; }
step() { : > "$T/env"; EXTRA_ENV=$1 GITHUB_ENV=$T/env bash -e "$T/step.sh" > /dev/null 2>&1; }

step '' && [ ! -s "$T/env" ] && ok "empty: nothing exported" || bad "empty"
step $'VERSION_BRIDGE=c-0123456789abcdef\nVERSION_X=2026.1.1-abc1234' && [ "$(wc -l < "$T/env")" -eq 2 ] && ok "two lines exported" || bad "good lines"
for v in $'VERSION_A=x\nBASH_ENV=/tmp/x' $'VERSION_A=x\r' 'VERSION_A=$(id)' 'PATH=/tmp' 'VERSION_A=a b' 'VERSION_A<<EOF'; do
  step "$v" && bad "exported: $(printf '%q' "$v")" || { [ ! -s "$T/env" ] && ok "refused: $(printf '%q' "$v")" || bad "partly exported: $v"; }
done
# --- the deploy gate (render_policy_cmd): source before any helmfile call, then the render of the apply, then apply
python3 -c '
import yaml
steps = yaml.safe_load(open(".github/workflows/deploy-helmfile.yml"))["jobs"]["deploy"]["steps"]
print(next(s["run"] for s in steps if s.get("name") == "Deploy using helmfile"), end="")
' | sed 's/\${{ *inputs\.deploy_dir *}}/deploy/; s/\${{ *inputs\.namespace || inputs\.environment *}}/ns1/g; s/\${{ *inputs\.environment *}}/dev/g' > "$T/deploystep.sh"
R=$T/repo; mkdir -p "$R/deploy" "$R/scripts" "$T/bin"
# The fake helmfile logs its arguments and a digest of its environment; template prints a render unique to the run.
cat > "$T/bin/helmfile" <<'SH'
#!/bin/sh
echo "helmfile $* env=$(env | grep -v '^_=' | LC_ALL=C sort | cksum | cut -d' ' -f1) cwd=${PWD##*/}" >> "$CALLS"
case " $* " in *" template "*) echo "kind: Render"; echo "id: $RENDER_ID" ;; esac
exit 0
SH
cat > "$T/bin/renderer" <<'SH'
#!/bin/sh
echo "renderer $*" >> "$CALLS"
in=$(cat)
[ "$1" = --check ] || { printf '%s\n' "$in"; exit 0; }
SH
cat > "$R/scripts/gate" <<'SH'
#!/bin/sh
case $1 in
source) echo "gate source cwd=${PWD##*/} env=$RENDER_POLICY_ENVIRONMENT ns=$RENDER_POLICY_NAMESPACE dir=$RENDER_POLICY_DEPLOY_DIR" >> "$CALLS"; [ -z "$GATE_SOURCE_FAILS" ] ;;
render) in=$(cat); echo "gate render $(printf '%s' "$in" | tr '\n' ' ')" >> "$CALLS"; [ -z "$GATE_RENDER_FAILS" ] ;;
*) exit 2 ;;
esac
SH
chmod +x "$T/bin/helmfile" "$T/bin/renderer" "$R/scripts/gate"
echo 'exit 0' > "$R/scripts/not-exec"; chmod -x "$R/scripts/not-exec"
gstep() { : > "$T/calls"; (cd "$R" && env -u GATE_SOURCE_FAILS -u GATE_RENDER_FAILS "$@" PATH="$T/bin:$PATH" CALLS="$T/calls" RUNNER_TEMP="$T" \
  RENDER_POLICY_ENVIRONMENT=dev RENDER_POLICY_NAMESPACE=ns1 RENDER_POLICY_DEPLOY_DIR=deploy bash -e "$T/deploystep.sh") > "$T/glog" 2>&1; }
calls() { sed -E 's/ env=[0-9]+//' "$T/calls" | tr '\n' '|'; }
id=render-$RANDOM$RANDOM

gstep PIN_IMAGES=false RENDER_POLICY_CMD= RENDER_ID=$id \
  && [ "$(calls)" = "helmfile -e dev -n ns1 apply cwd=deploy|" ] && ok "gate unset: a plain apply, nothing else" || { bad "gate unset"; cat "$T/calls" "$T/glog"; }
gstep PIN_IMAGES=false RENDER_POLICY_CMD=scripts/gate RENDER_ID=$id \
  && [ "$(calls)" = "gate source cwd=repo env=dev ns=ns1 dir=deploy|helmfile -e dev -n ns1 template cwd=deploy|gate render kind: Render id: $id|helmfile -e dev -n ns1 apply cwd=deploy|" ] \
  && ok "gate set: source, template, the gate on that render, then apply" || { bad "gate set"; cat "$T/calls" "$T/glog"; }
envs=$(sed -n 's/^helmfile .* env=\([0-9]*\) .*/\1/p' "$T/calls" | sort -u | wc -l)
[ "$envs" -eq 1 ] && ok "gate set: template and apply see the same environment" || bad "gate set: template and apply environments differ"
gstep PIN_IMAGES=false RENDER_POLICY_CMD=scripts/gate GATE_SOURCE_FAILS=1 RENDER_ID=$id; rc=$?
[ $rc -ne 0 ] && ! grep -q '^helmfile' "$T/calls" && grep -q 'refused the source' "$T/glog" && ok "gate: a refused source stops before any helmfile call" || { bad "gate source refusal"; cat "$T/calls"; }
gstep PIN_IMAGES=false RENDER_POLICY_CMD=scripts/gate GATE_RENDER_FAILS=1 RENDER_ID=$id; rc=$?
[ $rc -ne 0 ] && ! grep -q 'helmfile.* apply' "$T/calls" && grep -q 'refused the render' "$T/glog" && ok "gate: a refused render stops before apply" || { bad "gate render refusal"; cat "$T/calls"; }
gstep PIN_IMAGES=true IMAGE_PINS_RENDERER=$T/bin/renderer RENDER_POLICY_CMD=scripts/gate RENDER_ID=$id \
  && [ "$(calls)" = "gate source cwd=repo env=dev ns=ns1 dir=deploy|helmfile -e dev -n ns1 template --post-renderer $T/bin/renderer cwd=deploy|renderer --check|gate render kind: Render id: $id|helmfile -e dev -n ns1 apply --post-renderer $T/bin/renderer cwd=deploy|" ] \
  && ok "gate with pinned images: the gate reads the pinned render, apply keeps the renderer" || { bad "gate pinned"; cat "$T/calls" "$T/glog"; }
gstep PIN_IMAGES=true IMAGE_PINS_RENDERER=$T/bin/renderer RENDER_POLICY_CMD=scripts/gate GATE_RENDER_FAILS=1 RENDER_ID=$id; rc=$?
[ $rc -ne 0 ] && ! grep -q 'helmfile.* apply' "$T/calls" && ok "gate with pinned images: a refused render stops before apply" || bad "gate pinned refusal"
for p in ../repo/scripts/gate /bin/true scripts/../scripts/gate ./scripts/gate 'scripts/gate source' 'scripts/$(id)' scripts/missing scripts/not-exec $'scripts/gate\nx'; do
  gstep PIN_IMAGES=false RENDER_POLICY_CMD="$p" RENDER_ID=$id && bad "gate path accepted: $(printf '%q' "$p")" \
    || { [ ! -s "$T/calls" ] && ok "gate path refused before anything runs: $(printf '%q' "$p")" || bad "gate path partly ran: $p"; }
done
python3 - <<'PY' && ok "wiring: the input is optional and empty by default, reaches the step through env only" || bad "wiring of render_policy_cmd"
import yaml
w = yaml.safe_load(open(".github/workflows/deploy-helmfile.yml"))
i = w[True]["workflow_call"]["inputs"]["render_policy_cmd"]
assert i["type"] == "string" and i["default"] == "" and not i.get("required", False)
step = next(s for s in w["jobs"]["deploy"]["steps"] if s.get("name") == "Deploy using helmfile")
assert step["env"]["RENDER_POLICY_CMD"] == "${{ inputs.render_policy_cmd }}"
assert "render_policy_cmd" not in step["run"].replace("render_policy_cmd is not", "").replace("render_policy_cmd $RENDER", "")
run = step["run"]
assert run.index('"$policy" source') < run.index("cd ${{ inputs.deploy_dir }}")
PY

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
