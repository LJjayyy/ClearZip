"""Check the release hand-off wiring and execute its actual Bash guard.

These targeted workflow checks use the repository's indentation conventions;
they do not require installing a YAML parser in order to run the test suite.
"""
import os
import json
import tempfile
from pathlib import Path
import re
import subprocess
import textwrap
import unittest

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/release.yml"


class ReleaseWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        workflow = WORKFLOW.read_text()
        cls.jobs = {}
        for name in ("build", "publish"):
            match = re.search(rf"^  {name}:\n(.*?)(?=^  [\w-]+:\s*$|\Z)", workflow, re.M | re.S)
            if match is None:
                raise AssertionError(f"Missing workflow job: {name}")
            cls.jobs[name] = match.group(1)
        cls.build_steps = re.split(r"(?m)^      - ", cls.jobs["build"])[1:]
        cls.publish_steps = re.split(r"(?m)^      - ", cls.jobs["publish"])[1:]

    def step_using(self, steps, action):
        matches = [step for step in steps if re.search(rf"^        uses: {re.escape(action)}@", step, re.M)]
        self.assertEqual(len(matches), 1, f"Expected one {action} step")
        return matches[0]

    def test_publish_downloads_the_successful_build_output(self):
        build = self.jobs["build"]
        publish = self.jobs["publish"]
        upload = self.step_using(self.build_steps, "actions/upload-artifact")
        download = self.step_using(self.publish_steps, "actions/download-artifact")
        # Follow the actual references, rather than deriving a new name using the
        # publish attempt. This remains the same reference on a publish-only retry.
        upload_id = re.search(r"^        id: (\w+)\s*$", upload, re.M)
        self.assertIsNotNone(upload_id)
        self.assertIn("artifact_id: ${{ steps." + upload_id.group(1) + ".outputs.artifact-id }}", build)
        self.assertRegex(publish, r"(?m)^    needs: build$")
        self.assertIn("RELEASE_ARTIFACT_ID: ${{ needs.build.outputs.artifact_id }}", publish)
        self.assertIn("artifact-ids: ${{ env.RELEASE_ARTIFACT_ID }}", download)
        self.assertNotRegex(download, r"(?m)^          (name|pattern):")
        self.assertNotIn("github.run_attempt", publish)

    def test_full_rebuild_upload_names_do_not_collide(self):
        upload = self.step_using(self.build_steps, "actions/upload-artifact")
        self.assertRegex(upload, r"(?m)^          name: .*\$\{\{ github.run_id \}\}.*\$\{\{ github.run_attempt \}\}")
        self.assertNotRegex(upload, r"(?m)^          overwrite: true$")

    def guard(self):
        matches = [step for step in self.publish_steps if "id: validate_artifact" in step]
        self.assertEqual(len(matches), 1)
        guard = matches[0]
        download = self.step_using(self.publish_steps, "actions/download-artifact")
        self.assertLess(self.publish_steps.index(guard), self.publish_steps.index(download))
        self.assertIn("shell: bash", guard)
        script = re.search(r"^        run: \|\n(.*)\Z", guard, re.M | re.S)
        self.assertIsNotNone(script)
        return textwrap.dedent(script.group(1))

    def run_guard(self, artifact_id):
        return subprocess.run(
            ["bash", "-c", self.guard()],
            env={**os.environ, "RELEASE_ARTIFACT_ID": artifact_id},
            capture_output=True, text=True, timeout=5,
        )

    def test_missing_or_malformed_id_stops_before_download(self):
        for value in ("", " ", "0", "-1", "1,2", "123oops", "1\n2", "${{ missing.output }}"):
            with self.subTest(artifact_id=value):
                result = self.run_guard(value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("::error::", result.stdout)

    def test_single_artifact_id_is_accepted_on_retries(self):
        for value in ("1", "12345678901"):
            with self.subTest(artifact_id=value):
                # The current attempt must have no effect on the retained ID.
                for attempt in ("1", "2", "3"):
                    result = subprocess.run(
                        ["bash", "-c", self.guard()],
                        env={**os.environ, "RELEASE_ARTIFACT_ID": value, "GITHUB_RUN_ATTEMPT": attempt},
                        capture_output=True, text=True, timeout=5,
                    )
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_published_title_is_exact_version_and_release_is_latest(self):
        publish = next(step for step in self.publish_steps if "gh release create" in step)
        script = textwrap.dedent(re.search(r"^        run: \|\n(.*)\Z", publish, re.M | re.S).group(1))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "release").mkdir()
            (root / "release/package.dmg").write_bytes(b"fixture")
            stub = root / "gh"
            stub.write_text("#!/usr/bin/env python3\nimport json,os,sys\n"
                            "if sys.argv[1:3] == ['release','view']: sys.exit(1)\n"
                            "if sys.argv[1:3] == ['release','create']:\n"
                            " with open(os.environ['RECORDED_ARGS'],'w') as f: json.dump(sys.argv[1:],f)\n")
            stub.chmod(0o755)
            record = root / "args.json"
            # Exercise macOS's bundled Bash 3.2, including its nounset array behavior.
            result = subprocess.run(["/bin/bash", "-c", script], cwd=root, capture_output=True, text=True,
                                    env={**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
                                         "RELEASE_TAG": "v1.0.0", "RELEASE_COMMIT": "a" * 40,
                                         "RELEASE_EVENT": "workflow_dispatch", "GH_REPO": "example/repository",
                                         "RECORDED_ARGS": str(record)}, timeout=5)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            args = json.loads(record.read_text())
            self.assertEqual(args[args.index("--title") + 1], "v1.0.0")
            self.assertNotIn("--prerelease", args)
            self.assertIn("--latest=true", args)
            self.assertEqual(args[args.index("--target") + 1], "a" * 40)

    def test_download_integrity_and_flat_asset_directory(self):
        download = self.step_using(self.publish_steps, "actions/download-artifact")
        self.assertRegex(download, r"(?m)^          digest-mismatch: error$")
        self.assertRegex(download, r"(?m)^          path: release$")
        checksum = next(step for step in self.publish_steps if "sha256sum --check SHA256SUMS.txt" in step)
        publish = next(step for step in self.publish_steps if "gh release create" in step)
        self.assertLess(self.publish_steps.index(download), self.publish_steps.index(checksum))
        self.assertLess(self.publish_steps.index(checksum), self.publish_steps.index(publish))


if __name__ == "__main__":
    unittest.main(verbosity=2)
