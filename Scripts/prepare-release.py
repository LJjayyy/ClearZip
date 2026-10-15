#!/usr/bin/env python3
"""Validate a release tag and stage its DMG, checksum, and release notes."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil


def release_metadata(root, tag):
    if not re.fullmatch(r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", tag):
        raise ValueError("版本标签必须是 v数字.数字.数字，例如 v1.0.0")
    version = tag[1:]
    for name in ("Info.plist", "FinderExtension-Info.plist"):
        with (root / "Resources" / name).open("rb") as stream:
            info = plistlib.load(stream)
        if info["CFBundleShortVersionString"] != version:
            raise ValueError(f"{name} 的版本与标签 {tag} 不一致")
    changelog = (root / "CHANGELOG.md").read_text()
    section = re.search(
        rf"^## {re.escape(version)}(?: —[^\n]*)?\n(.*?)(?=^## |\Z)",
        changelog, re.M | re.S,
    )
    if not section or not section.group(1).strip():
        raise ValueError(f"CHANGELOG.md 缺少 {version} 的更新说明")
    return version, section.group(1).strip()


def stage_release(root, tag, architecture):
    version, changes = release_metadata(root, tag)
    if architecture not in ("arm64", "x86_64"):
        raise ValueError(f"不支持的处理器架构：{architecture}")
    source = root / "build" / f"ClearZip-{version}.dmg"
    if not source.is_file() or source.stat().st_size == 0:
        raise ValueError(f"缺少有效安装包：{source}")
    destination = root / "build" / "release"
    # A fresh directory prevents mixing packages from earlier architectures.
    destination.mkdir(parents=True, exist_ok=False)
    name = f"ClearZip-{version}-macOS-{architecture}.dmg"
    shutil.copyfile(source, destination / name)
    digest = hashlib.sha256((destination / name).read_bytes()).hexdigest()
    (destination / "SHA256SUMS.txt").write_text(f"{digest}  {name}\n")
    processor = "Apple Silicon（M 系列）" if architecture == "arm64" else "Intel"
    (destination / "release-notes.md").write_text(
        f"{changes}\n\n"
        f"### 下载与安装\n\n"
        f"- 系统要求：macOS 13 或更新版本；处理器：{processor}。\n"
        f"- 下载 `{name}`，打开后将 ClearZip 拖入 Applications。\n"
        "- 从“应用程序”打开一次，在应用中点击“访达扩展…”并启用。\n\n"
        "### 签名状态\n\n"
        "应用采用本地 ad hoc 签名，未使用 Developer ID 证书，尚未通过 Apple 公证。"
        "macOS 可能阻止首次打开。确认下载来源后，可按 Apple 官方说明，"
        "在“系统设置 → 隐私与安全性”中为此应用选择“仍要打开”。\n\n"
        "[Apple：安全地在 Mac 上打开 App](https://support.apple.com/zh-cn/102445)\n\n"
        "附件 `SHA256SUMS.txt` 可用于核对下载完整性。"
        "GitHub 自动附带的 Source code 文件是源码，不是安装包。\n"
    )
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("check", "stage"))
    parser.add_argument("tag")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    try:
        release_metadata(root, args.tag)
        if args.operation == "stage":
            print(stage_release(root, args.tag, platform.machine()))
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, f"发布准备失败：{error}\n")
    if args.operation == "check" and os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"tag={args.tag}\n")
    print(f"发布版本校验通过：{args.tag}")


if __name__ == "__main__":
    main()
