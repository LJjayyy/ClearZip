#!/usr/bin/env python3
"""Check URL exposure in the shipped bundle and rejected executable launches."""
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "build/ClearZip.app"
BINARY = APP / "Contents/MacOS/ClearZip"


class LaunchSecurityTests(unittest.TestCase):
    def test_application_includes_the_project_license(self):
        self.assertEqual((APP / "Contents/Resources/LICENSE.txt").read_bytes(), (ROOT / "LICENSE").read_bytes())

    def test_worker_is_background_only_and_bundled_with_same_version(self):
        with (APP / "Contents/Info.plist").open("rb") as handle:
            main = plistlib.load(handle)
        worker = APP / "Contents/Helpers/ClearZipWorker.app"
        with (worker / "Contents/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        self.assertEqual(info["CFBundleIdentifier"], "com.clearzip.mac.worker")
        self.assertEqual(info["CFBundleShortVersionString"], main["CFBundleShortVersionString"])
        self.assertEqual(info["CFBundleVersion"], main["CFBundleVersion"])
        self.assertTrue(info["LSUIElement"])
        self.assertNotIn("CFBundleURLTypes", info)
        self.assertNotIn("NSServices", info)
        self.assertEqual((worker / "Contents/Resources/LICENSE.txt").read_bytes(), (ROOT / "LICENSE").read_bytes())

    def test_public_url_handler_is_not_registered(self):
        for path in [ROOT / "Resources/Info.plist", APP / "Contents/Info.plist"]:
            with self.subTest(plist=path):
                with path.open("rb") as handle:
                    self.assertFalse(plistlib.load(handle).get("CFBundleURLTypes"))

    def test_old_links_and_malformed_requests_exit_without_compression(self):
        with tempfile.TemporaryDirectory(prefix="clearzip-launch-") as directory:
            root = Path(directory)
            source = root / "payload.txt"
            source.write_text("must not be compressed by an external link")
            legacy_url = f"clearzip://compress?path={source}"
            cases = [
                [legacy_url],
                ["--finder-compress"],
                ["--finder-compress", "--"],
                ["--finder-compress", str(source)],
                ["--finder-compress", "--", legacy_url],
                ["--finder-compress", "--", str(source), legacy_url],
                ["--finder-compress", "--", source.as_uri()],
                ["--finder-compress", "--", "relative/path"],
                ["--unknown", str(source)],
            ]
            for arguments in cases:
                with self.subTest(arguments=arguments):
                    result = subprocess.run(
                        [str(BINARY)] + arguments, cwd=root,
                        capture_output=True, text=True, timeout=5,
                    )
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertTrue(result.stderr.strip())
                    self.assertEqual(list(root.iterdir()), [source])
                    self.assertEqual(source.read_text(), "must not be compressed by an external link")


if __name__ == "__main__":
    unittest.main(verbosity=2)
