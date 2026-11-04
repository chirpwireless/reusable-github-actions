#!/usr/bin/env python3
"""Make the two-part ECR change in service checkouts.

For every checkout path given:
  1. everything under deploy/, or the directory named with --deploy-dir: ghcr.io/chirpwireless/<image> ->
     <registry>/chirpwireless/<image> on every non-comment line (values, templates, per-environment values, quoted or
     `image:` forms)
  2. .github/workflows: after every job that calls a reusable build-*.yml, a job that calls build-ecr-copy.yml.
     The build job itself never gets id-token: it runs the code of the service, and the copy job must not.
  3. .github/workflows: a workflow started by workflow_run starts only from a branch build. A pull request build is never
     copied to ECR and ends before the copy of the branch build of the same commit, so a deploy from it finds no image.

It edits files in place and never commits, pushes or opens a PR. It exits non-zero, and says why, when:
  - a service_name or a replaced image is not in the list of ECR images (--push-repos)
  - a replaced image is not built by a shared build job of this checkout (e.g. a sidecar built elsewhere) and is not
    named with --extra-image: its own workflow must copy it to ECR first
  - nothing changed and the checkout does not already point at ECR
  - a non-comment ghcr.io/chirpwireless reference is left in that directory
  - a build job holds id-token: write, in its own permissions or from the workflow's
  - a workflow_run workflow has no guard of the known form to extend

A failed run may leave the checkout half edited: `git restore .` before retrying.
--deploy-only / --workflows-only do just one of the two parts (the other is read for its checks, not written).
A repository with no deploy directory of its own takes --workflows-only and moves its image where it is deployed from.
"""
import argparse
import json
import re
import sys
from pathlib import Path

GHCR = "ghcr.io/chirpwireless/"
GHCR_REF = re.compile(r"ghcr\.io/chirpwireless/([A-Za-z0-9._-]+)")
ECR_REF = re.compile(r"\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/chirpwireless/")
BUILD_USES = re.compile(r"^(\s*)uses:\s*chirpwireless/reusable-github-actions/\.github/workflows/(build-[\w-]+)\.yml@")
COPY_WORKFLOW = "build-ecr-copy"
COPY_JOB = """
  ecr-copy-{job}:
    needs: [{job}]
    uses: chirpwireless/reusable-github-actions/.github/workflows/build-ecr-copy.yml@main
    permissions:
      id-token: write
      packages: read
    with:
      image: "{image}"
      version: ${{{{ needs.{job}.outputs.new-version }}}}
      digest: ${{{{ needs.{job}.outputs.image-digest }}}}
"""
SERVICE_NAME = re.compile(r"^\s*service_name:\s*[\"']?([A-Za-z0-9._-]+)[\"']?\s*(#.*)?$")
SKIP_DIRS = {".git", "node_modules"}
WORKFLOW_RUN = re.compile(r"^\s*workflow_run:\s*$", re.M)
SUCCESS_GUARD = "github.event.workflow_run.conclusion == 'success'"
BRANCH_BUILD_GUARD = f"{SUCCESS_GUARD} && github.event.workflow_run.event != 'pull_request'"


def known_images(push_repos: Path) -> set[str]:
    repos = json.loads(push_repos.read_text())["repos"]
    return {image for entry in repos.values() for image in entry["images"]}


def is_comment(line: str) -> bool:
    return line.lstrip().startswith("#")


def migrate_deploy(repo: Path, deploy_dir: str, registry: str, known: set[str], dry_run: bool) -> tuple[list[str], list[str], set[str]]:
    report, errors = [], []
    images: set[str] = set()
    deploy = repo / deploy_dir
    if not deploy.is_dir():
        return report, [f"{repo}: no {deploy_dir}/ directory"], images
    changed_lines = already = 0
    for path in sorted(p for p in deploy.rglob("*") if p.is_file() and not (SKIP_DIRS & set(p.parts))):
        try:
            lines = path.read_text().splitlines(keepends=True)
        except UnicodeDecodeError:
            continue
        touched = False
        for i, line in enumerate(lines):
            if is_comment(line):
                continue
            if ECR_REF.search(line):
                already += 1
            if GHCR in line:
                for image in GHCR_REF.findall(line):
                    images.add(image)
                    if image not in known:
                        errors.append(f"{path.relative_to(repo)}:{i + 1}: image '{image}' is not in the list of ECR images")
                lines[i] = line.replace(GHCR, f"{registry}/chirpwireless/")
                touched = True
                changed_lines += 1
        if touched and not dry_run:
            path.write_text("".join(lines))
    for path in sorted(p for p in deploy.rglob("*") if p.is_file()):
        try:
            for n, line in enumerate((path.read_text() if not dry_run else "").splitlines(), 1):
                if not is_comment(line) and "ghcr.io/chirpwireless" in line:
                    errors.append(f"{path.relative_to(repo)}:{n}: leftover ghcr.io/chirpwireless reference")
        except UnicodeDecodeError:
            continue
    if changed_lines:
        report.append(f"{deploy_dir}/: {changed_lines} line(s) changed")
    elif already:
        report.append(f"{deploy_dir}/: already points at ECR")
    else:
        errors.append(f"{deploy_dir}/: nothing changed and no ECR reference present")
    return report, errors, images


def guard_workflow_run(path: Path, text: str, dry_run: bool) -> tuple[list[str], list[str]]:
    if not WORKFLOW_RUN.search(text) or BRANCH_BUILD_GUARD in text:
        return [], []
    if text.count(SUCCESS_GUARD) != 1:
        return [], [f"{path.name}: expected one `{SUCCESS_GUARD}` to extend; add the pull request guard by hand"]
    if not dry_run:
        path.write_text(text.replace(SUCCESS_GUARD, BRANCH_BUILD_GUARD))
    return [f"{path.name}: starts only from a branch build"], []


def migrate_workflows(repo: Path, known: set[str], dry_run: bool) -> tuple[list[str], list[str], set[str]]:
    report, errors = [], []
    services: set[str] = set()
    callers = 0
    for path in sorted((repo / ".github/workflows").glob("*.y*ml")):
        text = path.read_text()
        lines = text.splitlines(keepends=True)
        i = 0
        edits = []
        while i < len(lines):
            m = BUILD_USES.match(lines[i])
            if not m:
                i += 1
                continue
            if m.group(2) == COPY_WORKFLOW:
                i += 1
                continue
            callers += 1
            indent = len(m.group(1))
            start = i
            while start > 0 and (not lines[start - 1].strip() or len(lines[start - 1]) - len(lines[start - 1].lstrip()) >= indent):
                start -= 1
            end = i + 1
            while end < len(lines) and (not lines[end].strip() or len(lines[end]) - len(lines[end].lstrip()) >= indent):
                end += 1
            block = lines[start:end]
            job = lines[start - 1].strip().rstrip(":")
            service = next((SERVICE_NAME.match(l).group(1) for l in block if SERVICE_NAME.match(l)), None)
            if service:
                services.add(service)
            if service is None or service not in known:
                errors.append(f"{path.name}:{i + 1}: service_name {service!r} is not in the list of ECR images")
            if any(re.match(r"^\s*id-token:\s*write", l) for l in block):
                errors.append(f"{path.name}:{i + 1}: build job holds id-token: write; only the copy job may")
            i = end
            if f"ecr-copy-{job}:" not in text:
                while end > start and not lines[end - 1].strip():
                    end -= 1
                edits.append((end, COPY_JOB.format(job=job, image=service)))
        for at, added in sorted(edits, reverse=True):
            lines.insert(at, added)
        if edits and not dry_run:
            path.write_text("".join(lines))
        if edits:
            report.append(f"{path.name}: copy job added after {len(edits)} build job(s)")
        if any(BUILD_USES.match(l) for l in lines) and re.search(r"^\s*id-token:\s*write", text.split("\njobs:", 1)[0], re.M):
            errors.append(f"{path.name}: the workflow gives id-token: write to its build jobs; only the copy job may")
        guarded, guard_errors = guard_workflow_run(path, "".join(lines), dry_run)
        report += guarded
        errors += guard_errors
    if callers == 0:
        errors.append(".github/workflows: no job calls a reusable build-*.yml")
    elif not report and not errors:
        report.append("workflows: copy jobs already present")
    return report, errors, services


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--registry", required=True, help="ECR registry host, e.g. <account>.dkr.ecr.eu-central-1.amazonaws.com")
    ap.add_argument("--push-repos", required=True, type=Path, help="hetzner-k8s live/ecr-push-role/ecr-push-repos.json (repositories, their branches and images)")
    ap.add_argument("--deploy-dir", default="deploy", help="directory holding the charts and values, relative to the checkout (default: deploy)")
    only = ap.add_mutually_exclusive_group()
    only.add_argument("--deploy-only", action="store_true", help="edit deploy/ only")
    only.add_argument("--workflows-only", action="store_true", help="edit .github/workflows only")
    ap.add_argument("--dry-run", action="store_true", help="report only; skips the leftover scan")
    ap.add_argument("--extra-image", action="append", default=[], help="image referenced under deploy/ whose own workflow already copies it to ECR")
    ap.add_argument("paths", nargs="+", type=Path, help="service checkouts")
    args = ap.parse_args()

    known = known_images(args.push_repos)
    rc = 0
    for repo in args.paths:
        print(repo)
        r1, e1, images = migrate_deploy(repo, args.deploy_dir, args.registry, known, args.dry_run or args.workflows_only)
        r2, e2, services = migrate_workflows(repo, known, args.dry_run or args.deploy_only)
        if args.workflows_only:
            r1, e1, images = [], [], set()
        if args.deploy_only:
            r2, e2 = [], []
        reports, errors = r1 + r2, e1 + e2
        if not args.workflows_only:
            for image in sorted(images - services - set(args.extra_image)):
                errors.append(f"image '{image}' is not built by a shared build job here; its own workflow must copy it to ECR (then pass --extra-image {image})")
        for line in reports:
            print(f"  {line}")
        for line in errors:
            print(f"  ERROR {line}")
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
