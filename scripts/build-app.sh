#!/usr/bin/env bash
# Builds build/Instagrammar.app. Usage: scripts/build-app.sh [--debug]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
[[ "${1:-}" == "--debug" ]] && CONFIG=debug

swift build -c "$CONFIG" --product Instagrammar
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Instagrammar"

APP=build/Instagrammar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Instagrammar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null
echo "$APP"
