#!/usr/bin/env bash
# Usage: same-config.sh <tag> <built> <registry> [<pushed>]: logs the digests and fails unless every given one equals <built>.
set -euo pipefail

tag=${1:?tag} built=${2:?built} registry=${3:?registry} pushed=${4:-}
state=false
[ -z "$pushed" ] || state=true
echo "content-image tag=$tag built_config=$built registry_config=$registry pushed=$state"
for d in "$built" "$registry" ${pushed:+"$pushed"}; do
  printf '%s' "$d" | grep -Eqx 'sha256:[0-9a-f]{64}' || { echo "::error::not a config digest: $d" >&2; exit 1; }
done
[ "$registry" = "$built" ] || { echo "::error::the build is not reproducible: built $built, registry $registry" >&2; exit 1; }
[ -z "$pushed" ] || [ "$pushed" = "$built" ] || { echo "::error::the pushed image differs from the checked build: built $built, pushed $pushed" >&2; exit 1; }
