#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/build"
APP_DIR="$OUTPUT_DIR/ClearZip.app"
if [[ ! -d "$APP_DIR" ]]; then
  printf '请先运行 bash Scripts/build.sh 构建应用。\n' >&2
  exit 1
fi
codesign --verify --deep --strict "$APP_DIR"
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_DIR/Contents/Info.plist")"
DMG_PATH="$OUTPUT_DIR/ClearZip-$APP_VERSION.dmg"
STAGING_DIR="$(mktemp -d "$OUTPUT_DIR/dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto --norsrc --noextattr --noacl --noqtn "$APP_DIR" "$STAGING_DIR/ClearZip.app"
ln -s /Applications "$STAGING_DIR/Applications"
cp "$PROJECT_DIR/Resources/DMG-安装说明.txt" "$STAGING_DIR/安装说明.txt"
cp "$PROJECT_DIR/LICENSE" "$STAGING_DIR/LICENSE.txt"
hdiutil create -volname "ClearZip $APP_VERSION" -srcfolder "$STAGING_DIR" \
  -fs HFS+ -format UDZO -nospotlight -ov "$DMG_PATH"
hdiutil verify "$DMG_PATH"
printf '已生成安装映像：%s\n' "$DMG_PATH"
