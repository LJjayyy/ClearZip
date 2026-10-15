#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/build"
APP_DIR="$OUTPUT_DIR/ClearZip.app"
EXTENSION_DIR="$APP_DIR/Contents/PlugIns/ClearZipFinder.appex"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$OUTPUT_DIR/module-cache"
export CLANG_MODULE_CACHE_PATH="$OUTPUT_DIR/module-cache"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$OUTPUT_DIR/module-cache" \
  "$PROJECT_DIR/Sources/Shared/CompressionRequest.swift" \
  "$PROJECT_DIR/Sources/ClearZip/ArchiveEngine.swift" \
  "$PROJECT_DIR/Sources/ClearZip/ArchiveFileSystem.swift" \
  "$PROJECT_DIR/Sources/ClearZip/AppDelegate.swift" \
  "$PROJECT_DIR/Sources/ClearZip/main.swift" \
  -o "$APP_DIR/Contents/MacOS/ClearZip"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE.txt"
if [[ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]]; then
  cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
mkdir -p "$EXTENSION_DIR/Contents/MacOS" "$EXTENSION_DIR/Contents/Resources"
xcrun swiftc -swift-version 5 -O -application-extension -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$OUTPUT_DIR/module-cache" \
  "$PROJECT_DIR/Sources/Shared/CompressionRequest.swift" \
  "$PROJECT_DIR/Sources/Shared/FinderRequestQueue.swift" \
  "$PROJECT_DIR/Sources/ClearZipFinder/FinderSync.swift" \
  "$PROJECT_DIR/Sources/ClearZipFinder/FinderWorkerHandoff.swift" \
  "$PROJECT_DIR/Sources/ClearZipFinder/main.swift" \
  -o "$EXTENSION_DIR/Contents/MacOS/ClearZipFinder"
cp "$PROJECT_DIR/Resources/FinderExtension-Info.plist" "$EXTENSION_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$EXTENSION_DIR/Contents/Resources/AppIcon.icns"
plutil -lint "$EXTENSION_DIR/Contents/Info.plist"
codesign --force --sign - --entitlements "$PROJECT_DIR/Resources/FinderExtension.entitlements" "$EXTENSION_DIR"
WORKER_DIR="$APP_DIR/Contents/Helpers/ClearZipWorker.app"
mkdir -p "$WORKER_DIR/Contents/MacOS" "$WORKER_DIR/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$OUTPUT_DIR/module-cache" \
  "$PROJECT_DIR/Sources/Shared/CompressionRequest.swift" \
  "$PROJECT_DIR/Sources/Shared/FinderRequestQueue.swift" \
  "$PROJECT_DIR/Sources/ClearZip/ArchiveEngine.swift" \
  "$PROJECT_DIR/Sources/ClearZip/ArchiveFileSystem.swift" \
  "$PROJECT_DIR/Sources/ClearZipWorker/main.swift" \
  -o "$WORKER_DIR/Contents/MacOS/ClearZipWorker"
cp "$PROJECT_DIR/Resources/Info.plist" "$WORKER_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.clearzip.mac.worker' \
  -c 'Set :CFBundleName ClearZipWorker' -c 'Set :CFBundleDisplayName ClearZipWorker' \
  -c 'Set :CFBundleExecutable ClearZipWorker' -c 'Delete :NSServices' \
  -c 'Delete :CFBundleIconFile' \
  -c 'Add :ClearZipRequestSource string com.clearzip.mac.finder' "$WORKER_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/LICENSE" "$WORKER_DIR/Contents/Resources/LICENSE.txt"
codesign --force --sign - "$WORKER_DIR"
plutil -lint "$APP_DIR/Contents/Info.plist"
codesign --force --sign - "$APP_DIR"
printf '已构建：%s\n' "$APP_DIR"
