#!/usr/bin/env bash
# Build, sign and install ATLAS.app (native arm64 on Apple Silicon).
#
#   scripts/build-app.sh              build + install to ~/Applications + link atlasctl + register MCP
#   INSTALL=0 scripts/build-app.sh    build into ./build only
#   UNIVERSAL=1 VERSION=1.2.0 ...      Apple Silicon + Intel binary, stamped with a version (releases)
#
# Signing uses your "Apple Development" certificate when present. A stable signing identity matters:
# macOS ties Accessibility/Automation grants to it, so ad-hoc builds lose those grants on every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); else ARCH_FLAGS=(--arch "$(uname -m)"); fi
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"
BIN="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)"

APP="build/ATLAS.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ATLAS" "$BIN/atlas-nm-host" "$BIN/atlasctl" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}" "$APP/Contents/Info.plist"
fi
cp Resources/ATLAS.icns "$APP/Contents/Resources/ATLAS.icns"
cp -R Extensions "$APP/Contents/Resources/Extensions"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}"
IDENTITY="${IDENTITY:--}"
echo "Signing with: $IDENTITY"
for helper in atlas-nm-host atlasctl; do
  codesign --force --timestamp=none --sign "$IDENTITY" --options runtime "$APP/Contents/MacOS/$helper"
done
codesign --force --timestamp=none --sign "$IDENTITY" --options runtime --entitlements Resources/ATLAS.entitlements "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"

if [[ "${INSTALL:-1}" == "1" ]]; then
  DEST="$HOME/Applications/ATLAS.app"
  mkdir -p "$HOME/Applications"
  osascript -e 'quit app id "com.atlas.tracker"' >/dev/null 2>&1 || true
  sleep 1
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  # Keep exactly one registered copy: a second ATLAS.app confuses LaunchServices and permission entries.
  rm -rf "$APP"
  mkdir -p "$HOME/.local/bin"
  ln -sf "$DEST/Contents/MacOS/atlasctl" "$HOME/.local/bin/atlasctl"
  echo "Installed $DEST (atlasctl → ~/.local/bin/atlasctl)"
  # Make ATLAS's data available to Claude (Claude Code sessions, including scheduled tasks).
  if command -v claude >/dev/null 2>&1; then
    claude mcp remove --scope user atlas >/dev/null 2>&1 || true
    claude mcp add --scope user atlas -- "$DEST/Contents/MacOS/atlasctl" mcp && echo "Registered MCP server 'atlas' for Claude"
  fi
fi
