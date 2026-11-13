#!/usr/bin/env bash
# Build the release macOS app and package it as a DMG in build/dist.
#
# Usage:
#   macos/package.sh                          # unsigned local build
#   macos/package.sh --sign "Developer ID Application: Name (TEAMID)"
#
# For distribution outside the Mac App Store, sign with a Developer ID and
# notarize afterwards, e.g.:
#   xcrun notarytool submit build/dist/LumaBerth-*.dmg --keychain-profile AC --wait
#   xcrun stapler staple build/dist/LumaBerth-*.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/^version: *\([0-9][0-9.]*\).*/\1/p' pubspec.yaml)
ARCH=$(uname -m)
APP="build/macos/Build/Products/Release/lumaberth.app"
DIST="build/dist"
DMG="$DIST/LumaBerth-$VERSION-macOS-$ARCH.dmg"

flutter build macos --release

if [[ "${1:-}" == "--sign" ]]; then
  if [[ -z "${2:-}" ]]; then
    echo "--sign requires a signing identity" >&2
    exit 1
  fi
  codesign --force --deep --options runtime --timestamp --sign "$2" "$APP"
fi

mkdir -p "$DIST"
rm -f "$DMG"
hdiutil create -volname "映格" -srcfolder "$APP" -ov -format UDZO "$DMG"
echo "Packaged $DMG"
