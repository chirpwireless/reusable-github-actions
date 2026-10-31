# Reusable GitHub Actions

This repository contains a set of GitHub actions and workflows which can be used by all the teams.
## Pushing images to AWS ECR next to ghcr

The `build-*` workflows (except `build-k8s-service.yml`) push the image to ghcr as before and, when ECR is configured, also to
`<registry>/<owner>/<service_name>:<version>`. It is opt-in per service and never changes a build that has not opted in:

- the calling job must grant `id-token: write` (a reusable workflow cannot raise it itself);
- the org Actions variables `AWS_ECR_PUSH_ROLE_ARN` and `AWS_ECR_REGISTRY` must be set.

If any of the three is missing, or AWS rejects the login, the `ecr-login` action logs it and the build continues with ghcr only.
`scripts/ecr-migrate-service.py --registry <host> <checkout>...` makes the two per-service edits (the image repository in
`deploy/values/common.yaml` and `id-token: write` in the build caller); it only edits files, run it per checkout and open the PR by hand.
