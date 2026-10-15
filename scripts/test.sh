#!/usr/bin/env bash
# Runs the test suite. Uses full Xcode when available (selected or at /Applications/Xcode.app
# with an accepted license); otherwise falls back to Command Line Tools, where Swift Testing
# needs extra framework search paths.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == /Library/Developer/CommandLineTools* ]]; then
    XCODE_DEV=/Applications/Xcode.app/Contents/Developer
    if [[ -d "$XCODE_DEV" ]] && DEVELOPER_DIR="$XCODE_DEV" xcrun --find swift >/dev/null 2>&1 \
        && DEVELOPER_DIR="$XCODE_DEV" xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
        export DEVELOPER_DIR="$XCODE_DEV"
    fi
fi

DEV="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ "$DEV" == /Library/Developer/CommandLineTools* ]]; then
    F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
    exec swift test -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" "$@"
else
    exec swift test "$@"
fi
