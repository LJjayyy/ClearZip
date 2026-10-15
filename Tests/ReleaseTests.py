import hashlib
import importlib.util
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "prepare_release", Path(__file__).resolve().parent.parent / "Scripts/prepare-release.py"
)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Resources").mkdir()
        for name in ("Info.plist", "FinderExtension-Info.plist"):
            (self.root / "Resources" / name).write_bytes(
                plistlib.dumps({"CFBundleShortVersionString": "0.1.2"})
            )
        (self.root / "CHANGELOG.md").write_text(
            "# 版本记录\n\n## 0.1.2 — 2026-10-13\n\n- 本次变化。\n\n"
            "## 0.1.1 — 2026-10-13\n\n- 旧版变化。\n"
        )

    def test_reject_malformed_tags(self):
        for tag in ("0.1.2", "v01.1.2", "v0.1.2;echo", "v0.1.2\n", "v0.1.2-beta", "../v0.1.2"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.release_metadata(self.root, tag)

    def test_both_bundle_versions_must_match(self):
        for name in ("Info.plist", "FinderExtension-Info.plist"):
            path = self.root / "Resources" / name
            original = path.read_bytes()
            path.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.1.3"}))
            with self.subTest(name=name), self.assertRaises(ValueError):
                release.release_metadata(self.root, "v0.1.2")
            path.write_bytes(original)

    def test_missing_or_empty_changelog_stops_release(self):
        for text in ("## 0.1.3\n\n- Changes\n", "## 0.1.2\n\n## 0.1.1\n\n- Old\n"):
            (self.root / "CHANGELOG.md").write_text(text)
            with self.assertRaises(ValueError):
                release.release_metadata(self.root, "v0.1.2")

    def test_missing_or_empty_package_stops_release(self):
        with self.assertRaises(ValueError):
            release.stage_release(self.root, "v0.1.2", "arm64")
        (self.root / "build").mkdir()
        (self.root / "build/ClearZip-0.1.2.dmg").touch()
        with self.assertRaises(ValueError):
            release.stage_release(self.root, "v0.1.2", "arm64")

    def test_unsupported_architecture_stops_release(self):
        with self.assertRaises(ValueError):
            release.stage_release(self.root, "v0.1.2", "unknown")

    def test_assets_checksum_architecture_and_notes(self):
        content = b"release package fixture\x00\xff"
        (self.root / "build").mkdir()
        (self.root / "build/ClearZip-0.1.2.dmg").write_bytes(content)
        for architecture, processor in (("arm64", "Apple Silicon"), ("x86_64", "Intel")):
            with self.subTest(architecture=architecture):
                directory = release.stage_release(self.root, "v0.1.2", architecture)
                name = f"ClearZip-0.1.2-macOS-{architecture}.dmg"
                self.assertEqual((directory / name).read_bytes(), content)
                self.assertEqual((directory / "SHA256SUMS.txt").read_text(),
                                 f"{hashlib.sha256(content).hexdigest()}  {name}\n")
                notes = (directory / "release-notes.md").read_text()
                self.assertIn("本次变化", notes)
                self.assertNotIn("旧版变化", notes)
                self.assertIn(processor, notes)
                self.assertIn("尚未通过 Apple 公证", notes)
                with self.assertRaises(FileExistsError):
                    release.stage_release(self.root, "v0.1.2", architecture)
                shutil.rmtree(directory)


if __name__ == "__main__":
    unittest.main(verbosity=2)
