import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "ecr-migrate-service.py"
REGISTRY = "123456789012.dkr.ecr.eu-central-1.amazonaws.com"
PUSH_REPOS = '{"repos": {"svc": {"refs": ["refs/heads/main"], "images": ["svc", "authz-proxy", "other"]}}}'

BUILD = """\
name: Build
on: [push]
jobs:
  build:
    uses: chirpwireless/reusable-github-actions/.github/workflows/build-go.yml@main
    permissions:
      contents: write
      packages: write
    with:
      service_name: "svc"
"""


def run(files, extra=()):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "push-repos.json").write_text(PUSH_REPOS)
        repo = root / "repo"
        for name, body in files.items():
            p = repo / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(textwrap.dedent(body) if not body.startswith("name:") else body)
        proc = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--registry", REGISTRY, "--push-repos", str(root / "push-repos.json"), *extra, str(repo)],
            capture_output=True, text=True,
        )
        out = {n: (repo / n).read_text() for n in files}
        return proc.returncode, proc.stdout, out


class MigrateTest(unittest.TestCase):
    def test_plain_and_quoted_and_image_forms(self):
        rc, out, files = run({
            ".github/workflows/pipeline-build.yml": BUILD,
            "deploy/values/common.yaml": "image:\n  repository: ghcr.io/chirpwireless/svc\n",
            "deploy/values/common.yaml.gotmpl": 'image:\n  repository: "ghcr.io/chirpwireless/svc"\n',
            "deploy/values/dev/values.yaml": "sidecar:\n  image: 'ghcr.io/chirpwireless/authz-proxy:1'\n",
        }, extra=("--extra-image", "authz-proxy"))
        self.assertEqual(rc, 0, out)
        for name in ("deploy/values/common.yaml", "deploy/values/common.yaml.gotmpl", "deploy/values/dev/values.yaml"):
            self.assertIn(REGISTRY + "/chirpwireless/", files[name])
            self.assertNotIn("ghcr.io", files[name])
        wf = files[".github/workflows/pipeline-build.yml"]
        self.assertIn("  ecr-copy-build:\n    needs: [build]\n", wf)
        self.assertIn('      image: "svc"\n', wf)
        self.assertIn("${{ needs.build.outputs.image-digest }}", wf)
        build_job = wf.split("  ecr-copy-build:")[0]
        self.assertNotIn("id-token", build_job)

    def test_comment_lines_are_skipped_and_do_not_count_as_done(self):
        rc, out, _ = run({
            ".github/workflows/pipeline-build.yml": BUILD,
            "deploy/values/common.yaml": "# repository: ghcr.io/chirpwireless/svc\nreplicaCount: 1\n",
        })
        self.assertEqual(rc, 1)
        self.assertIn("nothing changed", out)

    def test_leftover_reference_fails(self):
        rc, out, _ = run({
            ".github/workflows/pipeline-build.yml": BUILD,
            "deploy/values/common.yaml": "image:\n  repository: ghcr.io/chirpwireless/svc\n",
            "deploy/values/dev/values.yaml": "registryHost: ghcr.io/chirpwireless\n",
        })
        self.assertEqual(rc, 1)
        self.assertIn("leftover", out)

    def test_image_built_elsewhere_needs_extra_image_flag(self):
        rc, out, _ = run({
            ".github/workflows/pipeline-build.yml": BUILD,
            "deploy/values/common.yaml": "image:\n  repository: ghcr.io/chirpwireless/svc\n",
            "deploy/values/dev/values.yaml": "sidecar:\n  image: ghcr.io/chirpwireless/authz-proxy:1\n",
        })
        self.assertEqual(rc, 1)
        self.assertIn("not built by a shared build job", out)

    def test_unknown_image_in_values_fails(self):
        rc, out, _ = run({
            ".github/workflows/pipeline-build.yml": BUILD,
            "deploy/values/common.yaml": "image:\n  repository: ghcr.io/chirpwireless/not-in-the-list\n",
        })
        self.assertEqual(rc, 1)
        self.assertIn("not in the list of ECR images", out)

    def test_unknown_service_name_fails(self):
        rc, out, _ = run({
            ".github/workflows/pipeline-build.yml": BUILD.replace('"svc"', '"ghost"'),
            "deploy/values/common.yaml": "image:\n  repository: ghcr.io/chirpwireless/svc\n",
        })
        self.assertEqual(rc, 1)
        self.assertIn("service_name 'ghost'", out)

    def test_every_build_job_gets_a_copy_job(self):
        two = BUILD + BUILD.split("jobs:\n")[1].replace("  build:", "  build-worker:").replace('"svc"', '"other"')
        rc, out, files = run({
            ".github/workflows/pipeline-build.yml": two,
            "deploy/values/common.yaml": "image:\n  repository: ghcr.io/chirpwireless/svc\n",
        })
        self.assertEqual(rc, 0, out)
        wf = files[".github/workflows/pipeline-build.yml"]
        self.assertEqual(wf.count("build-ecr-copy.yml@main"), 2)
        self.assertIn("needs: [build-worker]", wf)
        self.assertIn('image: "other"', wf)

    def test_build_job_with_id_token_fails(self):
        wf = BUILD.replace("      packages: write\n", "      packages: write\n      id-token: write\n")
        rc, out, _ = run({
            ".github/workflows/pipeline-build.yml": wf,
            "deploy/values/common.yaml": "image:\n  repository: ghcr.io/chirpwireless/svc\n",
        })
        self.assertEqual(rc, 1)
        self.assertIn("only the copy job may", out)

    def test_copy_job_lands_before_the_next_job(self):
        wf = BUILD + "\n  other:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: echo ok\n"
        rc, out, files = run({
            ".github/workflows/pipeline-build.yml": wf,
            "deploy/values/common.yaml": "image:\n  repository: ghcr.io/chirpwireless/svc\n",
        })
        self.assertEqual(rc, 0, out)
        text = files[".github/workflows/pipeline-build.yml"]
        self.assertLess(text.index("ecr-copy-build:"), text.index("  other:"))

    def test_chart_outside_deploy_needs_the_flag(self):
        files = {
            ".github/workflows/pipeline-build.yml": BUILD,
            "charts/svc/values.yaml": "image:\n  repository: ghcr.io/chirpwireless/svc\n",
        }
        rc, out, unchanged = run(files)
        self.assertEqual(rc, 1)
        self.assertIn("no deploy/ directory", out)
        self.assertIn("ghcr.io/chirpwireless/svc", unchanged["charts/svc/values.yaml"])
        rc, out, moved = run(files, extra=("--deploy-dir", "charts"))
        self.assertEqual(rc, 0, out)
        self.assertIn("charts/: 1 line(s) changed", out)
        self.assertIn(REGISTRY + "/chirpwireless/svc", moved["charts/svc/values.yaml"])
        self.assertIn("  ecr-copy-build:\n", moved[".github/workflows/pipeline-build.yml"])

    def test_chart_outside_deploy_keeps_the_leftover_check(self):
        rc, out, _ = run({
            ".github/workflows/pipeline-build.yml": BUILD,
            "charts/svc/values.yaml": "image:\n  repository: ghcr.io/chirpwireless/unknown\n",
        }, extra=("--deploy-dir", "charts"))
        self.assertEqual(rc, 1)
        self.assertIn("image 'unknown' is not in the list of ECR images", out)

    def test_workflow_without_final_newline(self):
        rc, out, files = run({
            ".github/workflows/pipeline-build.yml": BUILD.rstrip("\n"),
            "deploy/values/common.yaml": "image:\n  repository: ghcr.io/chirpwireless/svc\n",
        })
        self.assertEqual(rc, 0, out)
        self.assertIn('service_name: "svc"\n  ecr-copy-build:\n', files[".github/workflows/pipeline-build.yml"])

    def test_workflows_only_leaves_deploy_untouched(self):
        rc, out, files = run({
            ".github/workflows/pipeline-build.yml": BUILD,
            "deploy/values/common.yaml": "image:\n  repository: ghcr.io/chirpwireless/svc\n",
        }, extra=("--workflows-only",))
        self.assertEqual(rc, 0, out)
        self.assertIn("ghcr.io/chirpwireless/svc", files["deploy/values/common.yaml"])
        self.assertIn("build-ecr-copy.yml", files[".github/workflows/pipeline-build.yml"])

    def test_deploy_only_leaves_workflow_untouched(self):
        rc, out, files = run({
            ".github/workflows/pipeline-build.yml": BUILD,
            "deploy/values/common.yaml": "image:\n  repository: ghcr.io/chirpwireless/svc\n",
        }, extra=("--deploy-only",))
        self.assertEqual(rc, 0, out)
        self.assertNotIn("build-ecr-copy", files[".github/workflows/pipeline-build.yml"])
        self.assertIn(".dkr.ecr.", files["deploy/values/common.yaml"])

    def test_second_run_is_a_clean_no_op(self):
        files = {
            ".github/workflows/pipeline-build.yml": BUILD,
            "deploy/values/common.yaml": "image:\n  repository: ghcr.io/chirpwireless/svc\n",
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "push-repos.json").write_text(PUSH_REPOS)
            repo = root / "repo"
            for n, b in files.items():
                (repo / n).parent.mkdir(parents=True, exist_ok=True)
                (repo / n).write_text(b)
            cmd = [sys.executable, "-I", str(SCRIPT), "--registry", REGISTRY, "--push-repos", str(root / "push-repos.json"), str(repo)]
            self.assertEqual(subprocess.run(cmd, capture_output=True, text=True).returncode, 0)
            second = subprocess.run(cmd, capture_output=True, text=True)
            self.assertEqual(second.returncode, 0, second.stdout)
            self.assertIn("already", second.stdout)


if __name__ == "__main__":
    unittest.main()
