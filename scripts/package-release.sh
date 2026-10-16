#!/usr/bin/env bash
# Builds the release app and zips it for a GitHub release:
# build/Instagrammar-<version>-macos-arm64.zip. Ad-hoc signed, not notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh >/dev/null
VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
ZIP="build/Instagrammar-${VERSION}-macos-arm64.zip"
rm -f "$ZIP"
# ditto keeps the bundle's extended attributes and signature intact (plain `zip` can break them).
ditto -c -k --keepParent build/Instagrammar.app "$ZIP"
echo "$ZIP"
