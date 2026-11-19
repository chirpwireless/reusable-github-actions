#!/usr/bin/env bash
# Prints the config digest from the build-push-action metadata JSON in METADATA; fails when it is missing or malformed.
set -euo pipefail

digest=$(printf '%s' "${METADATA:-}" | jq -r '.["containerimage.config.digest"] // empty')
printf '%s' "$digest" | grep -Eqx 'sha256:[0-9a-f]{64}' || { echo "::error::the build did not report a config digest" >&2; exit 1; }
echo "$digest"
