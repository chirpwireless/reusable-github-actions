#!/usr/bin/env python3
"""Runs the setup-terraform action's script on a stub curl and a throwaway signing key."""
import os
import pathlib
import subprocess
import tempfile
import unittest
import zipfile

import yaml

ACTION_DIR = pathlib.Path(__file__).resolve().parents[2] / ".github/actions/setup-terraform"
VERSION = "1.2.3"
ZIP = f"terraform_{VERSION}_linux_amd64.zip"
STUB_CURL = """#!/bin/bash
while [ $# -gt 1 ]; do
  if [ "$1" = -o ]; then out=$2; fi
  shift
done
cp "$RELEASE_DIR/$(basename "$1")" "$out"
"""


def gpg(home, *args, **kwargs):
    return subprocess.run(["gpg", "--homedir", str(home), "--batch", "--yes", *args], check=True, capture_output=True, text=True, **kwargs)


def new_key(home, name):
    home.mkdir(mode=0o700)
    gpg(home, "--passphrase", "", "--quick-generate-key", f"{name} <{name}@test.invalid>", "rsa2048", "sign", "never")
    fingerprint = next(line.split(":")[9] for line in gpg(home, "--with-colons", "--fingerprint").stdout.splitlines() if line.startswith("fpr"))
    return home, fingerprint


class SetupTerraformTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.release = self.root / "release"
        self.release.mkdir()
        self.signer, self.fingerprint = new_key(self.root / "signer", "release")
        self.key_file = self.root / "release-key.asc"
        self.key_file.write_text(gpg(self.signer, "--armor", "--export").stdout)
        with zipfile.ZipFile(self.release / ZIP, "w") as archive:
            info = zipfile.ZipInfo("terraform")
            info.external_attr = 0o755 << 16
            archive.writestr(info, '#!/bin/bash\necho "Terraform v1.2.3"\n')
        digest = subprocess.run(["sha256sum", ZIP], cwd=self.release, check=True, capture_output=True, text=True).stdout
        self.sums = self.release / f"terraform_{VERSION}_SHA256SUMS"
        self.sums.write_text(digest)
        self.sign(self.signer)

    def sign(self, home):
        gpg(home, "--passphrase", "", "--pinentry-mode", "loopback", "--detach-sign", "--output", f"{self.sums}.sig", str(self.sums))

    def run_action(self, version=VERSION, fingerprint=None):
        script = yaml.safe_load((ACTION_DIR / "action.yaml").read_text())["runs"]["steps"][0]["run"]
        bin_dir = self.root / "bin"
        bin_dir.mkdir(exist_ok=True)
        (bin_dir / "curl").write_text(STUB_CURL)
        (bin_dir / "curl").chmod(0o755)
        runner_temp = self.root / "runner"
        runner_temp.mkdir(exist_ok=True)
        github_path = self.root / "github_path"
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", VERSION=version, KEY_FILE=str(self.key_file),
                   KEY_FINGERPRINT=fingerprint or self.fingerprint, RUNNER_TEMP=str(runner_temp), GITHUB_PATH=str(github_path),
                   RELEASE_DIR=str(self.release))
        return subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True), github_path

    def test_signed_release_with_the_right_checksum_is_installed(self):
        result, github_path = self.run_action()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Terraform v1.2.3", result.stdout)
        self.assertTrue(pathlib.Path(github_path.read_text().strip(), "terraform").exists())

    def test_another_key_in_the_file_is_refused(self):
        result, _ = self.run_action(fingerprint="0" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not have the pinned fingerprint", result.stdout)

    def test_a_signature_of_another_key_is_refused(self):
        other, _ = new_key(self.root / "other", "other")
        self.sign(other)
        result, _ = self.run_action()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not signed by the HashiCorp release key", result.stdout)

    def test_edited_checksums_are_refused(self):
        self.sums.write_text(self.sums.read_text() + "0" * 64 + "  other.zip\n")
        result, _ = self.run_action()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not signed by the HashiCorp release key", result.stdout)

    def test_a_swapped_archive_is_refused(self):
        (self.release / ZIP).write_bytes(b"not the signed archive")
        result, github_path = self.run_action()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(github_path.exists())

    def test_a_version_that_is_not_exact_is_refused(self):
        result, _ = self.run_action(version="latest")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid Terraform version", result.stdout)

    def test_bundled_key_has_the_pinned_fingerprint(self):
        action = yaml.safe_load((ACTION_DIR / "action.yaml").read_text())
        pinned = action["runs"]["steps"][0]["env"]["KEY_FINGERPRINT"]
        home = self.root / "bundled"
        home.mkdir(mode=0o700)
        gpg(home, "--quiet", "--import", str(ACTION_DIR / "hashicorp-release-key.asc"))
        first = next(line.split(":")[9] for line in gpg(home, "--with-colons", "--fingerprint").stdout.splitlines() if line.startswith("fpr"))
        self.assertEqual(first, pinned)


if __name__ == "__main__":
    unittest.main()
