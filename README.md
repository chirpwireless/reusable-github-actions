# Reusable GitHub Actions

This repository contains a set of GitHub actions and workflows which can be used by all the teams.

## Copying images to AWS ECR

`build-ecr-copy.yml` copies one image from ghcr to `<registry>/<owner>/<image>:<version>` by digest and proves the tag in
ECR holds that digest. A service opts in with one job next to its build job; `scripts/ecr-migrate-service.py` adds it and
moves the addresses under `deploy/`, or `--deploy-dir charts` where the chart lives there:

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

- The build job never gets `id-token`: it runs the code of the service. Each repository has its own AWS role, and it trusts
  this one workflow file on the branches listed for that repository, so a job that runs service code cannot assume it.
- The job runs on a GitHub-hosted runner and checks nothing out: the builder VMs are shared with service builds.
- It runs on `main`, `master`, `develop` and `dev` and is skipped elsewhere, so pull request images stay on ghcr.
- Repositories, their branches and their images are listed in `hetzner-k8s/live/ecr-push-role/ecr-push-repos.json`. A branch
  or an image that is not there gets a red job and no deploy until it has a line. The role reads the variable
  `AWS_ECR_PUSH_ROLE_PREFIX` plus the repository name.
- Outside `main` and `master` a tag must end in `-<branch>`, the form `calendar-version` gives: only those two write tags that
  production accepts, and tags in ECR are immutable.
- A failed copy fails the build of that branch, and Auto Deploy does not start from it. A pull request build skips the copy,
  so `scripts/ecr-migrate-service.py` also makes the Auto Deploy of a migrated service start only from a branch build, when
  its copy is done. `version-fetch` alone cannot do this: a pull request build can end before the branch build has published
  its version. Auto Deploy runs from the default branch, so a service that merges into another branch first puts this guard
on its default branch with a PR of its own.
- A service that does not call this workflow gets no copy job, but every build and deploy uses `version-publish` and
  `version-fetch` at `@main`, so a merge here changes those two for all services at once.

Tests: `python3 -I scripts/tests/test_ecr_migrate_service.py`, `python3 -I scripts/tests/test_ecr_copy.py`,
`node --test .github/actions/version-fetch/script.test.js`.
