#!/usr/bin/env python3
"""Desktop-only integration check against a clone of the built background worker."""
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="clearzip-sandbox-handoff-") as directory:
    root = Path(directory)
    app = root / "Probe.app"
    binary = app / "Contents/MacOS/Probe"
    binary.parent.mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.clearzip.tests.handoff",
        "CFBundleExecutable": "Probe", "CFBundlePackageType": "APPL", "LSUIElement": True,
    }))
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(ROOT / "build/module-cache"),
        str(ROOT / "Sources/Shared/CompressionRequest.swift"),
        str(ROOT / "Sources/Shared/FinderRequestQueue.swift"),
        str(ROOT / "Sources/ClearZipFinder/FinderWorkerHandoff.swift"),
        str(ROOT / "Tests/FinderHandoffProbe.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements",
                    str(ROOT / "Resources/FinderExtension.entitlements"), str(app)], check=True)
    worker = root / "Worker.app"
    shutil.copytree(ROOT / "build/ClearZip.app/Contents/Helpers/ClearZipWorker.app", worker)
    worker_info = worker / "Contents/Info.plist"
    info = plistlib.loads(worker_info.read_bytes())
    info["ClearZipRequestSource"] = "com.clearzip.tests.handoff"
    info["CFBundleIdentifier"] = "com.clearzip.tests.worker"
    worker_info.write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", str(worker)], check=True)
    source = root / "分享资料"
    source.mkdir()
    payload = source / "原文.txt"
    payload.write_text("sandbox handoff payload\n")
    (source / ".DS_Store").write_text("filtered metadata")
    subprocess.run([str(binary), str(worker), str(source)], check=True, timeout=30)
    archive = root / "分享资料.zip"
    deadline = time.monotonic() + 15
    while not archive.exists() and time.monotonic() < deadline:
        time.sleep(0.1)
    with zipfile.ZipFile(archive) as zipped:
        assert zipped.read("分享资料/原文.txt") == payload.read_bytes()
        assert not any(part == ".DS_Store" or part == "__MACOSX" or part.startswith("._")
                       for name in zipped.namelist() for part in name.split("/"))
    assert (source / ".DS_Store").read_text() == "filtered metadata"
    print("PASS: actual sandbox -> private queue -> background worker -> clean ZIP")
