#!/usr/bin/env bash
# Build a universal ATLAS.app and wrap it in a drag-to-Applications disk image for GitHub Releases.
#
#   scripts/package-release.sh 1.0.0     -> dist/ATLAS-1.0.0.dmg (+ .sha256)
#
# Without a Developer ID certificate the app is ad-hoc signed and not notarized, so macOS asks people to
# approve it once (System Settings → Privacy & Security → Open Anyway). Set SIGN_IDENTITY to a
# "Developer ID Application" identity to sign properly; notarization is a separate step.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/package-release.sh <version>}"

INSTALL=0 UNIVERSAL=1 VERSION="$VERSION" SIGN_IDENTITY="${SIGN_IDENTITY:--}" scripts/build-app.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto build/ATLAS.app "$STAGE/ATLAS.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
DMG="dist/ATLAS-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "ATLAS $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
shasum -a 256 "$DMG" | awk '{print $1}' > "$DMG.sha256"
echo "$DMG  $(du -h "$DMG" | cut -f1)  sha256 $(cat "$DMG.sha256")"
lipo -archs build/ATLAS.app/Contents/MacOS/ATLAS
