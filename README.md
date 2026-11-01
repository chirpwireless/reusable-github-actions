# Reusable GitHub Actions

This repository contains a set of GitHub actions and workflows which can be used by all the teams.

## Copying images to AWS ECR

`build-ecr-copy.yml` copies one image from ghcr to `<registry>/<owner>/<image>:<version>` by digest and proves the tag in
ECR holds that digest. A service opts in with one job next to its build job; `scripts/ecr-migrate-service.py` adds it and
moves the addresses under `deploy/`:

```yaml
ecr-copy-build:
  needs: [build]
  uses: chirpwireless/reusable-github-actions/.github/workflows/build-ecr-copy.yml@main
  permissions:
    id-token: write
    packages: read
  with:
    image: "bff"
    version: ${{ needs.build.outputs.new-version }}
    digest: ${{ needs.build.outputs.image-digest }}
```

- The build job never gets `id-token`: it runs the code of the service. The AWS role trusts this one workflow file, on
  protected branches of the organization, so a job that runs service code cannot assume it.
- The job runs on a GitHub-hosted runner and checks nothing out: the builder VMs are shared with service builds.
- It runs on `main`, `master`, `develop` and `dev` and is skipped elsewhere, so pull request images stay on ghcr.
  `dev` is trusted per repository in `hetzner-k8s/live/ecr-push-role`: another repository building on `dev` gets a red job
  and no deploy until it has a line there.
- A repository writes the image named after it. Any other image needs a line in
  `.github/actions/ecr-copy/allowed-images.json`, because the role itself can write the whole namespace.
- A failed copy fails the build of that branch, and Auto Deploy does not start from it. A pull request build of the same
  commit still can: it skips the copy, succeeds, and `version-fetch` then picks the branch build, so the deploy fails on the
  missing image and helmfile rolls back.
- A service that does not call this workflow gets no copy job, but every build and deploy uses `version-publish` and
  `version-fetch` at `@main`, so a merge here changes those two for all services at once.

Tests: `python3 -I scripts/tests/test_ecr_migrate_service.py`, `python3 -I scripts/tests/test_ecr_copy.py`,
`node --test .github/actions/version-fetch/script.test.js`.
