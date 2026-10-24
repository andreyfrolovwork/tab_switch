#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/WindowSwitcher.app"
BIN="$APP/Contents/MacOS/WindowSwitcher"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

xcrun swiftc \
  -swift-version 5 \
  -O \
  -g \
  -target arm64-apple-macos14.0 \
  -framework AppKit \
  -framework ApplicationServices \
  -framework ScreenCaptureKit \
  -o "$BIN" \
  Sources/Windows.swift \
  Sources/SystemHotkeys.swift \
  Sources/Thumbnails.swift \
  Sources/SwitcherView.swift \
  Sources/Switcher.swift \
  Sources/KeyMonitor.swift \
  Sources/main.swift

cp Info.plist "$APP/Contents/Info.plist"
SIGN_ID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(WindowSwitcher Local\)".*/\1/p' | head -1)"
if [[ -n "${SIGN_ID}" ]]; then
  codesign --force --sign "${SIGN_ID}" --identifier com.andrey.windowswitcher "$APP"
else
  codesign --force --sign - --identifier com.andrey.windowswitcher "$APP"
fi
echo "built $APP"
