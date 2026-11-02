#!/usr/bin/env python3
"""Runs the ecr-copy action's script against a stub docker: same digest passes, different digest and a denied target fail, a new tag is copied."""
import os
import pathlib
import subprocess
import tempfile
import unittest

import yaml

ACTION = pathlib.Path(__file__).resolve().parents[2] / ".github/actions/ecr-copy/action.yaml"
STUB = """#!/bin/bash
case "$3" in
  inspect)
    case "$4" in
      ecr/same:*) echo '{"manifest":1}' ;;
      ghcr/same:*) echo '{"manifest":1}' ;;
      ecr/diff:*) echo '{"manifest":1}' ;;
      ghcr/diff:*) echo '{"manifest":2}' ;;
      ecr/denied:*) echo "unexpected status from HEAD request: 403 Forbidden" >&2; exit 1 ;;
      ecr/new:*) echo "not found: 404" >&2; exit 1 ;;
      *) echo '{"manifest":3}' ;;
    esac ;;
  create) echo created ;;
esac
"""


class EcrCopyTest(unittest.TestCase):
    def run_action(self, source: str, target: str) -> subprocess.CompletedProcess:
        script = yaml.safe_load(ACTION.read_text())["runs"]["steps"][0]["run"]
        with tempfile.TemporaryDirectory() as tmp:
            docker = pathlib.Path(tmp, "docker")
            docker.write_text(STUB)
            docker.chmod(0o755)
            env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}", SOURCE=source, TARGET=target,
                       REGISTRY="ecr", RUNNER_TEMP=tmp, GITHUB_REF="refs/heads/main")
            return subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True, cwd=tmp)

    def test_same_digest_passes(self):
        self.assertEqual(self.run_action("ghcr/same:1", "ecr/same:1").returncode, 0)

    def test_different_digest_fails(self):
        r = self.run_action("ghcr/diff:1", "ecr/diff:1")
        self.assertEqual(r.returncode, 1)
        self.assertIn("is not the one just built", r.stdout)

    def test_denied_target_fails(self):
        r = self.run_action("ghcr/x:1", "ecr/denied:1")
        self.assertEqual(r.returncode, 1)
        self.assertIn("may not push", r.stdout)

    def test_new_tag_is_copied(self):
        self.assertEqual(self.run_action("ghcr/x:1", "ecr/new:1").returncode, 0)


if __name__ == "__main__":
    unittest.main()
