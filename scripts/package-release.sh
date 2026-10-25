#!/usr/bin/env bash
# Build a universal ATLAS.app and wrap it in a drag-to-Applications disk image for GitHub Releases.
#
#   scripts/package-release.sh 1.0.0     -> dist/ATLAS-1.0.0.dmg (+ .sha256)
#
# Releases are signed with the self-signed "ATLAS Release" certificate (SIGN_IDENTITY), whose hash the in-app
# updater pins and which keeps macOS permission grants stable across versions. It isn't Developer ID, so
# macOS asks people to approve the first download once (System Settings → Privacy & Security → Open Anyway).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/package-release.sh <version>}"

INSTALL=0 UNIVERSAL=1 VERSION="$VERSION" CHANNEL=release SIGN_IDENTITY="${SIGN_IDENTITY:-ATLAS Release}" scripts/build-app.sh
codesign -v -R='identifier "com.atlas.tracker" and certificate root = H"7d3eed29018c8a73ae6f33dc246d854a65c46a9a"' build/ATLAS.app \
  || echo "warning: not signed with the ATLAS Release certificate; installed copies won't accept it as an update" >&2

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto build/ATLAS.app "$STAGE/ATLAS.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
DMG="dist/ATLAS-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "ATLAS $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
shasum -a 256 "$DMG" | awk '{print $1}' > "$DMG.sha256"
# A fixed name too, so releases/latest/download/ATLAS.dmg always points at the newest version.
cp "$DMG" dist/ATLAS.dmg
echo "$DMG  $(du -h "$DMG" | cut -f1)  sha256 $(cat "$DMG.sha256")"
lipo -archs build/ATLAS.app/Contents/MacOS/ATLAS
