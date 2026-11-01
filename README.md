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
- A repository writes the image named after it. Any other image needs a line in
  `.github/actions/ecr-copy/allowed-images.json`, because the role itself can write the whole namespace.
- Any failure fails the build, and Auto Deploy runs only after a successful Build workflow.
- Services that do not call this workflow are not affected.

Tests: `python3 -I scripts/tests/test_ecr_migrate_service.py`, `python3 -I scripts/tests/test_ecr_copy.py`,
`node --test .github/actions/version-fetch/script.test.js`.
