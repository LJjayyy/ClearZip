#!/usr/bin/env python3
"""Exercise the shipped executable and inspect real ZIP entries, not mocked calls."""
import concurrent.futures
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "build/ClearZip.app/Contents/MacOS/ClearZip"


class CleanZipTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="clearzip-test-")
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def compress(self, *paths, output=None, success=True):
        args = [str(BINARY), "--compress"]
        if output is not None:
            args += ["--output-directory", str(output)]
        result = subprocess.run(args + ["--"] + list(map(str, paths)), capture_output=True, text=True)
        if not success:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            return result
        self.assertEqual(result.returncode, 0, result.stderr)
        path = Path(result.stdout.rstrip("\n"))
        self.assertTrue(path.is_file())
        self.assertEqual(list(self.root.glob(".clearzip-*")), [])
        return path

    def test_metadata_removed_and_original_untouched(self):
        folder = self.root / "资料"
        folder.mkdir()
        file = folder / "你好.txt"
        file.write_bytes(b"hello\x00world")
        subprocess.run(["/usr/bin/xattr", "-w", "com.apple.ResourceFork", "resource fork", str(file)], check=True)
        subprocess.run(["/usr/bin/xattr", "-w", "com.clearzip.test", "private metadata", str(file)], check=True)
        (folder / ".DS_Store").write_text("Finder settings")
        (folder / "._你好.txt").write_text("AppleDouble")
        (folder / "__MACOSX").mkdir()
        (folder / "__MACOSX/hidden").write_text("metadata")
        nested = folder / "nested"
        nested.mkdir()
        (nested / ".DS_Store").touch()
        (nested / "._junk").touch()
        (folder / ".gitignore").write_text("build/")
        archive = self.compress(folder)
        self.assertEqual(archive.name, "资料.zip")
        with zipfile.ZipFile(archive) as z:
            names = z.namelist()
            self.assertTrue(any("你好.txt" in n for n in names), names)
            for name in names:
                for component in name.split("/"):
                    self.assertNotEqual(component, ".DS_Store")
                    self.assertNotEqual(component, "__MACOSX")
                    self.assertFalse(component.startswith("._"), name)
            self.assertEqual(z.read("资料/你好.txt"), b"hello\x00world")
            self.assertEqual(z.read("资料/.gitignore"), b"build/")
            extracted = self.root / "unpacked"
            subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(extracted)], check=True)
            attrs = subprocess.check_output(["/usr/bin/xattr", str(extracted / "资料/你好.txt")], text=True).splitlines()
            self.assertNotIn("com.apple.ResourceFork", attrs)
            self.assertNotIn("com.clearzip.test", attrs)
        self.assertEqual(subprocess.check_output(["/usr/bin/xattr", "-p", "com.apple.ResourceFork", str(file)]).rstrip(b"\n"), b"resource fork")
        self.assertEqual(subprocess.check_output(["/usr/bin/xattr", "-p", "com.clearzip.test", str(file)]).rstrip(b"\n"), b"private metadata")
        self.assertTrue((folder / ".DS_Store").exists())

    def test_empty_folder(self):
        folder = self.root / "empty"
        folder.mkdir()
        with zipfile.ZipFile(self.compress(folder)) as z:
            self.assertIn("empty/", z.namelist())

    def test_unusual_names_and_executable(self):
        name = "-文 件 ' \" $ ` [x]\n.txt"
        file = self.root / name
        file.write_text("payload")
        file.chmod(0o755)
        # Newline in the output name needs byte-exact handling, bypass the line-oriented helper.
        result = subprocess.run([str(BINARY), "--compress", "--", str(file)], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = self.root / (name + ".zip")
        with zipfile.ZipFile(archive) as z:
            self.assertEqual(z.namelist(), [name])
            self.assertEqual(z.read(name), b"payload")
            self.assertEqual((z.getinfo(name).external_attr >> 16) & 0o111, 0o111)

    def test_symlinks_are_not_followed(self):
        folder = self.root / "links"
        folder.mkdir()
        outside = self.root / "secret.txt"
        outside.write_text("outside")
        (folder / "external").symlink_to(outside)
        (folder / "dangling").symlink_to("does-not-exist")
        (folder / "loop").symlink_to(".")
        with zipfile.ZipFile(self.compress(folder)) as z:
            self.assertEqual(z.read("links/external"), str(outside).encode())
            self.assertTrue(stat.S_ISLNK(z.getinfo("links/external").external_attr >> 16))
            self.assertEqual(z.read("links/dangling"), b"does-not-exist")
            self.assertEqual(z.read("links/loop"), b".")

    def test_single_selected_symlink(self):
        link = self.root / "alias"
        link.symlink_to("missing")
        with zipfile.ZipFile(self.compress(link)) as z:
            self.assertEqual(z.read("alias"), b"missing")

    def test_no_overwrite_including_dangling_output_link(self):
        file = self.root / "one.txt"
        file.write_text("one")
        original = self.root / "one.txt.zip"
        original.write_bytes(b"do not overwrite")
        (self.root / "one.txt 2.zip").symlink_to("missing")
        archive = self.compress(file)
        self.assertEqual(archive.name, "one.txt 3.zip")
        self.assertEqual(original.read_bytes(), b"do not overwrite")
        self.assertTrue((self.root / "one.txt 2.zip").is_symlink())

    def test_multiple_sources_same_name(self):
        a = self.root / "a"
        b = self.root / "b"
        a.mkdir()
        b.mkdir()
        (a / "same.txt").write_text("a")
        (b / "same.txt").write_text("b")
        archive = self.compress(a / "same.txt", b / "same.txt")
        self.assertEqual(archive.name, "归档.zip")
        with zipfile.ZipFile(archive) as z:
            self.assertEqual(z.read("same.txt"), b"a")
            self.assertEqual(z.read("same.txt (2)"), b"b")

    def test_nested_selection_deduplicated(self):
        folder = self.root / "folder"
        folder.mkdir()
        file = folder / "one"
        file.write_text("one")
        with zipfile.ZipFile(self.compress(file, folder, folder)) as z:
            self.assertEqual(z.namelist().count("folder/one"), 1)
            self.assertNotIn("one", z.namelist())

    def test_parallel_publication(self):
        file = self.root / "parallel"
        file.write_bytes(os.urandom(1024 * 1024))
        def run(_):
            result = subprocess.run([str(BINARY), "--compress", "--", str(file)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return Path(result.stdout.strip())
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            results = list(pool.map(run, range(3)))
        self.assertEqual(len(set(results)), 3)
        for path in results:
            with zipfile.ZipFile(path) as z:
                self.assertEqual(z.read("parallel"), file.read_bytes())
        self.assertEqual(list(self.root.glob(".clearzip-*")), [])

    def test_invalid_source_and_only_metadata_fail_without_output(self):
        self.compress(self.root / "missing", success=False)
        metadata = self.root / ".DS_Store"
        metadata.touch()
        self.compress(metadata, success=False)
        self.assertEqual(list(self.root.glob("*.zip")), [])
        self.assertEqual(list(self.root.glob(".clearzip-*")), [])

    def test_destination_within_source_rejected_including_alias(self):
        folder = self.root / "folder"
        folder.mkdir()
        self.compress(folder, output=folder, success=False)
        alias = self.root / "alias"
        alias.symlink_to(folder, target_is_directory=True)
        self.compress(folder, output=alias, success=False)
        self.assertEqual(list(folder.iterdir()), [])

    def test_special_file_fails_and_cleans_staging(self):
        fifo = self.root / "pipe"
        os.mkfifo(fifo)
        self.compress(fifo, success=False)
        self.assertEqual(list(self.root.glob(".clearzip-*")), [])
        self.assertEqual(list(self.root.glob("*.zip")), [])

    def test_explicit_destination(self):
        file = self.root / "one"
        file.write_text("one")
        output = self.root / "output"
        output.mkdir()
        self.assertEqual(self.compress(file, output=output).parent, output)


if __name__ == "__main__":
    unittest.main(verbosity=2)
