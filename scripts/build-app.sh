#!/usr/bin/env bash
# Build ATLAS.app (native arm64 on Apple Silicon) with an ad-hoc signature.
# Notifications, EventKit prompts and launch-at-login need a real bundle, so use this rather than `swift run` for daily use.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
ARCH="$(uname -m)"
swift build -c "$CONFIG" --arch "$ARCH"
BIN="$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)"
APP="build/ATLAS.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ATLAS" "$APP/Contents/MacOS/ATLAS"
cp "$BIN/atlas-nm-host" "$APP/Contents/MacOS/atlas-nm-host"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Extensions "$APP/Contents/Resources/Extensions"
# Ad-hoc signature. For distribution, sign with a Developer ID and notarize instead.
codesign --force --sign - --options runtime "$APP/Contents/MacOS/atlas-nm-host"
codesign --force --sign - --options runtime "$APP"
echo "Built $APP"
