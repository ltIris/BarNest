#!/bin/zsh
# @Author lt_xiaoyi
# @Description 构建并签名 BarNest 应用
# @Version 1.0
set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/.build/BarNest.app"
MACOS="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS" "$APP/Contents/Resources"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/BarNest.icns" "$APP/Contents/Resources/BarNest.icns"

swiftc -O \
  -target arm64-apple-macosx27.2 \
  -o "$MACOS/BarNest" \
  "$ROOT/Sources/main.swift" \
  "$ROOT/Sources/AppDelegate.swift" \
  "$ROOT/Sources/MenuBarBridge.swift" \
  "$ROOT/Sources/HotKeyMonitor.swift" \
  "$ROOT/Sources/SystemItemClickBridge.swift" \
  "$ROOT/Sources/IconStore.swift" \
  "$ROOT/Sources/MenuBarScanner.swift" \
  "$ROOT/Sources/MenuBarAction.swift" \
  "$ROOT/Sources/AudioActivity.swift" \
  "$ROOT/Sources/NowPlayingEntry.swift" \
  "$ROOT/Sources/NowPlayingBar.swift" \
  "$ROOT/Sources/IconConfig.swift" \
  "$ROOT/Sources/SystemStats.swift" \
  "$ROOT/Sources/ScreenLocator.swift" \
  "$ROOT/Sources/WindowManager.swift" \
  "$ROOT/Sources/PreferencesWindow.swift" \
  "$ROOT/Sources/PopupPanel.swift" \
  "$ROOT/Sources/StatusBarController.swift"

# 用本机自签证书签名（不要改回 ad-hoc！）
# ad-hoc 签名的 designated requirement 是 cdhash，每次重编译都会变，
# macOS 的辅助功能授权（TCC）就会失效，用户每次都得重新勾一遍。
# 自签证书的 DR 绑定证书指纹，重编译不影响授权。
# 注意：证书名是钥匙串里的既有身份（"NotchTool Local Signing"），
# 与 App 显示名无关，**不要跟着改名**——改了 find-identity 找不到，
# 就会静默退回 ad-hoc 签名，TCC 授权随之失效。
SIGN_ID="NotchTool Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  codesign --force --sign "$SIGN_ID" "$APP" 2>/dev/null || codesign --force --sign - "$APP" 2>/dev/null || true
else
  codesign --force --sign - "$APP" 2>/dev/null || true
fi

echo "构建完成：$APP"
