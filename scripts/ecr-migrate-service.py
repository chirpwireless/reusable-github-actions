#!/usr/bin/env python3
"""Make the two-part ECR change in service checkouts.

For every checkout path given:
  1. everything under deploy/: ghcr.io/chirpwireless/<image> -> <registry>/chirpwireless/<image> on every
     non-comment line (values, templates, per-environment values, quoted or `image:` forms)
  2. .github/workflows: `id-token: write` in the permissions of every job that calls a reusable build-*.yml

It edits files in place and never commits, pushes or opens a PR. It exits non-zero, and says why, when:
  - a service_name or a replaced image is not a repository in the ECR registry stack (--registry-stack)
  - a replaced image is not built by a shared build job of this checkout (e.g. a sidecar built elsewhere) and is not
    named with --extra-image: its own workflow must copy it to ECR first
  - nothing changed and the checkout does not already point at ECR
  - a non-comment ghcr.io/chirpwireless reference is left under deploy/
  - a build job has no permissions block, or id-token is set to something other than write

A failed run may leave the checkout half edited: `git restore .` before retrying.
--deploy-only / --workflows-only do just one of the two parts (the other is read for its checks, not written).
"""
import argparse
import re
import sys
from pathlib import Path

GHCR = "ghcr.io/chirpwireless/"
GHCR_REF = re.compile(r"ghcr\.io/chirpwireless/([A-Za-z0-9._-]+)")
ECR_REF = re.compile(r"\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/chirpwireless/")
BUILD_USES = re.compile(r"^(\s*)uses:\s*chirpwireless/reusable-github-actions/\.github/workflows/build-[\w-]+\.yml@")
SERVICE_NAME = re.compile(r"^\s*service_name:\s*[\"']?([A-Za-z0-9._-]+)[\"']?\s*(#.*)?$")
SKIP_DIRS = {".git", "node_modules"}


def known_repositories(stack: Path) -> set[str]:
    text = stack.read_text()
    m = re.search(r"repository_names\s*=\s*\[(.*?)\]", text, re.S)
    if not m:
        sys.exit(f"{stack}: no repository_names list found")
    return set(re.findall(r'"([^"]+)"', m.group(1)))


def is_comment(line: str) -> bool:
    return line.lstrip().startswith("#")


def migrate_deploy(repo: Path, registry: str, known: set[str], dry_run: bool) -> tuple[list[str], list[str], set[str]]:
    report, errors = [], []
    images: set[str] = set()
    deploy = repo / "deploy"
    if not deploy.is_dir():
        return report, [f"{repo}: no deploy/ directory"], images
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
                        errors.append(f"{path.relative_to(repo)}:{i + 1}: image '{image}' is not a repository in the ECR registry stack")
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
        report.append(f"deploy/: {changed_lines} line(s) changed")
    elif already:
        report.append("deploy/: already points at ECR")
    else:
        errors.append("deploy/: nothing changed and no ECR reference present")
    return report, errors, images


def migrate_workflows(repo: Path, known: set[str], dry_run: bool) -> tuple[list[str], list[str], set[str]]:
    report, errors = [], []
    services: set[str] = set()
    callers = 0
    for path in sorted((repo / ".github/workflows").glob("*.y*ml")):
        lines = path.read_text().splitlines(keepends=True)
        i = 0
        edits = []
        while i < len(lines):
            m = BUILD_USES.match(lines[i])
            if not m:
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
            service = next((SERVICE_NAME.match(l).group(1) for l in block if SERVICE_NAME.match(l)), None)
            if service:
                services.add(service)
            if service is None or service not in known:
                errors.append(f"{path.name}:{i + 1}: service_name {service!r} is not a repository in the ECR registry stack")
            perm = next((k for k in range(start, end) if re.match(rf"^ {{{indent}}}permissions:\s*$", lines[k])), None)
            if perm is None:
                errors.append(f"{path.name}:{i + 1}: build job has no permissions block; add one by hand with id-token: write")
            else:
                last = perm + 1
                have = None
                while last < end and lines[last].strip() and len(lines[last]) - len(lines[last].lstrip()) > indent:
                    if lines[last].strip().startswith("id-token:"):
                        have = lines[last]
                    last += 1
                if have is None:
                    edits.append((last, " " * (indent + 2) + "id-token: write\n"))
                elif "write" not in have:
                    errors.append(f"{path.name}:{i + 1}: id-token is set to a non-write value")
            i = end
        for at, text in sorted(edits, reverse=True):
            lines.insert(at, text)
        if edits and not dry_run:
            path.write_text("".join(lines))
        if edits:
            report.append(f"{path.name}: id-token: write added to {len(edits)} job(s)")
    if callers == 0:
        errors.append(".github/workflows: no job calls a reusable build-*.yml")
    elif not report and not errors:
        report.append("workflows: already have id-token: write")
    return report, errors, services


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--registry", required=True, help="ECR registry host, e.g. <account>.dkr.ecr.eu-central-1.amazonaws.com")
    ap.add_argument("--registry-stack", required=True, type=Path, help="hetzner-k8s live/ecr-registry/terragrunt.hcl (the repository list)")
    only = ap.add_mutually_exclusive_group()
    only.add_argument("--deploy-only", action="store_true", help="edit deploy/ only")
    only.add_argument("--workflows-only", action="store_true", help="edit .github/workflows only")
    ap.add_argument("--dry-run", action="store_true", help="report only; skips the leftover scan")
    ap.add_argument("--extra-image", action="append", default=[], help="image referenced under deploy/ whose own workflow already copies it to ECR")
    ap.add_argument("paths", nargs="+", type=Path, help="service checkouts")
    args = ap.parse_args()

    known = known_repositories(args.registry_stack)
    rc = 0
    for repo in args.paths:
        print(repo)
        r1, e1, images = migrate_deploy(repo, args.registry, known, args.dry_run or args.workflows_only)
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
