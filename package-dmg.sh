#!/bin/zsh
# @Author lt_xiaoyi
# @Description 将已构建的 BarNest 应用打包为可下载的 DMG
# @Version 1.0
set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/.build/BarNest.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Info.plist")
OUTPUT="$ROOT/dist/BarNest-$VERSION-arm64.dmg"

if [[ ! -d "$APP" ]]; then
  echo "未找到 $APP，请先运行 ./build.sh" >&2
  exit 1
fi

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/BarNest.app"
ln -s /Applications "$STAGING/Applications"
mkdir -p "$ROOT/dist"
hdiutil create -volname BarNest -srcfolder "$STAGING" -format UDZO -ov "$OUTPUT"
echo "打包完成：$OUTPUT"
