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
echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
