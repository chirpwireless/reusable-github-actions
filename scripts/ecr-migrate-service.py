#!/usr/bin/env python3
"""Make the two-line ECR change in service checkouts.

For every checkout path given (or listed one per line in --list):
  1. deploy/values/common.yaml: image.repository ghcr.io/<owner>/<name> -> <registry>/<owner>/<name>
  2. the build caller workflow: add `id-token: write` to the permissions of the job that
     calls reusable-github-actions build-*.yml

Edits files in place and prints what changed; it never commits, pushes or opens a PR.
Idempotent: a checkout that is already migrated is reported as unchanged.
"""
import argparse
import re
import sys
from pathlib import Path

REPO_LINE = re.compile(r"^(\s*repository:\s*)ghcr\.io/([^/\s]+/\S+)\s*$")
BUILD_USES = re.compile(r"^(\s*)uses:\s*chirpwireless/reusable-github-actions/\.github/workflows/build-[\w-]+\.yml@")


def migrate_values(path: Path, registry: str, dry_run: bool) -> str:
    if not path.exists():
        return "no common.yaml"
    lines = path.read_text().splitlines(keepends=True)
    changed = 0
    for i, line in enumerate(lines):
        m = REPO_LINE.match(line.rstrip("\n"))
        if m:
            lines[i] = f"{m.group(1)}{registry}/{m.group(2)}\n"
            changed += 1
    if changed and not dry_run:
        path.write_text("".join(lines))
    return f"{changed} repository line(s) changed" if changed else "unchanged"


def migrate_workflow(path: Path, dry_run: bool) -> str:
    lines = path.read_text().splitlines(keepends=True)
    uses_idx = next((i for i, l in enumerate(lines) if BUILD_USES.match(l)), None)
    if uses_idx is None:
        return "not a build caller"
    job_indent = len(BUILD_USES.match(lines[uses_idx]).group(1))
    perm_idx = None
    for i in range(uses_idx + 1, len(lines)):
        line = lines[i]
        if line.strip() and len(line) - len(line.lstrip()) < job_indent:
            break
        if re.match(rf"^ {{{job_indent}}}permissions:\s*$", line):
            perm_idx = i
            break
    if perm_idx is None:
        return "NEEDS MANUAL EDIT: build job has no permissions block"
    end = perm_idx + 1
    while end < len(lines) and lines[end].strip() and len(lines[end]) - len(lines[end].lstrip()) > job_indent:
        if lines[end].strip().startswith("id-token:"):
            return "unchanged" if "write" in lines[end] else "NEEDS MANUAL EDIT: id-token is set to a non-write value"
        end += 1
    entry_indent = " " * (job_indent + 2)
    lines.insert(end, f"{entry_indent}id-token: write\n")
    if not dry_run:
        path.write_text("".join(lines))
    return "id-token: write added"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--registry", required=True, help="ECR registry host, e.g. <account>.dkr.ecr.eu-central-1.amazonaws.com")
    ap.add_argument("--list", help="file with one checkout path per line")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("paths", nargs="*", help="service checkouts")
    args = ap.parse_args()

    paths = [Path(p) for p in args.paths]
    if args.list:
        paths += [Path(l.strip()) for l in Path(args.list).read_text().splitlines() if l.strip() and not l.startswith("#")]
    if not paths:
        ap.error("give at least one checkout path")

    rc = 0
    for repo in paths:
        print(f"{repo}")
        print(f"  common.yaml: {migrate_values(repo / 'deploy/values/common.yaml', args.registry, args.dry_run)}")
        callers = sorted((repo / ".github/workflows").glob("*.y*ml"))
        results = [(w.name, migrate_workflow(w, args.dry_run)) for w in callers]
        results = [r for r in results if r[1] != "not a build caller"]
        if not results:
            print("  workflow: NEEDS MANUAL EDIT: no build caller found")
            rc = 1
        for name, res in results:
            print(f"  {name}: {res}")
            if res.startswith("NEEDS"):
                rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
