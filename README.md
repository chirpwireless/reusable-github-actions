# Reusable GitHub Actions

This repository contains a set of GitHub actions and workflows which can be used by all the teams.
## Copying images to AWS ECR next to ghcr

The `build-*` workflows (except `build-k8s-service.yml`) push the image to ghcr exactly as before. After that, on a push to
`main`, `master`, `develop`, `dev` or `test`, the `ecr-copy` action copies it registry-to-registry to
`<registry>/<owner>/<service_name>:<version>` (`docker buildx imagetools create`). Pull-request images stay on ghcr.
It is opt-in per service:

- the calling job must grant `id-token: write` (a reusable workflow cannot raise it itself);
- the org Actions variables `AWS_ECR_PUSH_ROLE_ARN` and `AWS_ECR_REGISTRY` must be set.

If any of these is missing, the ref is not an integration branch, or AWS rejects the login or the copy, the build continues
with ghcr only. The one exception: on an integration branch, when the service's `deploy/` already names an ECR registry, a
missing copy fails the build, because the deploy would otherwise fail later with an image that does not exist.
The AWS side only trusts jobs that run these workflows from `reusable-github-actions@main`.

`scripts/ecr-migrate-service.py` makes the per-service edits (every `ghcr.io/chirpwireless/` image under `deploy/`, and
`id-token: write` in every build job). Images built by a service's own job are copied with the reusable `build-ecr-copy.yml` workflow (inputs `service_name`, `version`). Run the script tests with `python3 -I scripts/tests/test_ecr_migrate_service.py`.
