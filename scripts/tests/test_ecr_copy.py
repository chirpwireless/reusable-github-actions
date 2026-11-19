import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ACTION = Path(__file__).resolve().parents[2] / ".github/actions/ecr-copy"
DIGEST = "sha256:" + "a" * 64
OTHER = "sha256:" + "b" * 64
REGISTRY = "123456789012.dkr.ecr.eu-central-1.amazonaws.com"

FAKE_AWS = """#!/usr/bin/env bash
echo "aws $*" >> "$CALLS"
if [ -f "$ECR_STATE" ]; then cat "$ECR_STATE"; exit 0; fi
if [ -n "${AWS_ERROR:-}" ]; then echo "$AWS_ERROR" >&2; exit 254; fi
echo "An error occurred (ImageNotFoundException) when calling DescribeImages" >&2
exit 254
"""

FAKE_DOCKER = """#!/usr/bin/env bash
echo "docker $*" >> "$CALLS"
[ -n "${COPY_RESULT:-}" ] && echo "$COPY_RESULT" > "$ECR_STATE"
exit "${DOCKER_RC:-0}"
"""


def executable(path, body):
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


def copy(image="svc", digest=DIGEST, version="2026.111.1-abc1234", ref="refs/heads/main", present=None, env=None):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        executable(bin_dir / "aws", FAKE_AWS)
        executable(bin_dir / "docker", FAKE_DOCKER)
        calls = root / "calls"
        state = root / "state"
        if present:
            state.write_text(present)
        full_env = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "CALLS": str(calls),
            "ECR_STATE": str(state),
            "IMAGE": image,
            "VERSION": version,
            "DIGEST": digest,
            "REGISTRY": REGISTRY,
            "GITHUB_REPOSITORY": "chirpwireless/svc",
            "GITHUB_REF": ref,
            **(env or {}),
        }
        proc = subprocess.run(["bash", str(ACTION / "copy.sh")], capture_output=True, text=True, env=full_env)
        return proc.returncode, proc.stdout + proc.stderr, calls.read_text() if calls.exists() else ""


class CopyTest(unittest.TestCase):
    def test_copies_by_digest_and_proves_the_result(self):
        rc, out, calls = copy(env={"COPY_RESULT": DIGEST})
        self.assertEqual(rc, 0, out)
        self.assertIn(f"--prefer-index=false --tag {REGISTRY}/chirpwireless/svc:2026.111.1-abc1234 ghcr.io/chirpwireless/svc@{DIGEST}", calls)
        self.assertEqual(calls.count("aws ecr describe-images"), 2)

    def test_same_digest_on_existing_tag_is_a_no_op(self):
        rc, out, calls = copy(present=DIGEST)
        self.assertEqual(rc, 0, out)
        self.assertNotIn("docker", calls)

    def test_other_digest_on_existing_tag_fails(self):
        rc, out, calls = copy(present=OTHER)
        self.assertEqual(rc, 1)
        self.assertIn("already holds", out)
        self.assertNotIn("docker", calls)

    def test_wrong_digest_after_copy_fails(self):
        rc, out, _ = copy(env={"COPY_RESULT": OTHER})
        self.assertEqual(rc, 1)
        self.assertIn("after the copy", out)

    def test_failed_copy_fails(self):
        rc, _, _ = copy(env={"DOCKER_RC": "1"})
        self.assertNotEqual(rc, 0)

    def test_aws_failure_is_not_taken_for_a_missing_tag(self):
        rc, _, calls = copy(env={"AWS_ERROR": "AccessDeniedException"})
        self.assertNotEqual(rc, 0)
        self.assertNotIn("docker", calls)

    def test_develop_writes_its_own_tag(self):
        rc, out, _ = copy(version="2026.111.1-abc1234-develop", ref="refs/heads/develop", env={"COPY_RESULT": DIGEST})
        self.assertEqual(rc, 0, out)

    def test_dev_writes_its_own_tag(self):
        rc, out, _ = copy(version="2026.111.1-abc1234-dev", ref="refs/heads/dev", env={"COPY_RESULT": DIGEST})
        self.assertEqual(rc, 0, out)

    def test_other_branches_cannot_write_a_production_tag(self):
        for ref in ("refs/heads/develop", "refs/heads/dev"):
            rc, out, calls = copy(version="2026.111.1-abc1234", ref=ref, env={"COPY_RESULT": DIGEST})
            self.assertEqual(rc, 1, ref)
            self.assertIn("may only write tags ending in", out)
            self.assertEqual(calls, "")

    def test_a_branch_cannot_write_the_tag_of_another_branch(self):
        rc, out, calls = copy(version="2026.111.1-abc1234-develop", ref="refs/heads/dev")
        self.assertEqual(rc, 1)
        self.assertEqual(calls, "")

    def test_branch_name_is_matched_as_the_build_writes_it(self):
        rc, out, _ = copy(version="2026.111.1-abc1234-release-1-2", ref="refs/heads/release/1.2", env={"COPY_RESULT": DIGEST})
        self.assertEqual(rc, 0, out)

    def test_main_and_master_write_production_tags(self):
        for ref in ("refs/heads/main", "refs/heads/master"):
            rc, out, _ = copy(ref=ref, env={"COPY_RESULT": DIGEST})
            self.assertEqual(rc, 0, out)

    def test_a_ref_that_is_not_a_branch_is_refused(self):
        for ref in ("refs/pull/7/merge", "refs/tags/v1", "refs/heads/"):
            rc, _, calls = copy(ref=ref)
            self.assertEqual(rc, 1, ref)
            self.assertEqual(calls, "")

    def test_bad_inputs_are_refused(self):
        for kwargs in ({"digest": "latest"}, {"version": "a b"}, {"image": "svc;id"}):
            rc, out, calls = copy(**kwargs)
            self.assertEqual(rc, 1, kwargs)
            self.assertEqual(calls, "")


if __name__ == "__main__":
    unittest.main()
