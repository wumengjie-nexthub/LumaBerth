#!/usr/bin/env bash
# Build, sign with a stable identity and launch the macOS app.
#
# Ad-hoc signing ("-", the Flutter template default) gives every rebuild a new
# code signature, so macOS treats it as a different app: the Photos grant is
# dropped and the Keychain item is refused, which is why the system asks for the
# password and the photo permission again after each rebuild. Signing with a
# real identity keeps the signature stable, so both grants stick.
#
# Usage:
#   macos/dev-run.sh                       # use the first available identity
#   CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" macos/dev-run.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/macos/Build/Products/Debug/lumaberth.app"
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(.*\)"/\1/p' | head -1)}"

flutter build macos --debug

if [[ -n "$IDENTITY" ]]; then
  echo "Signing with: $IDENTITY"
  codesign --force --deep --options runtime --timestamp=none \
    --sign "$IDENTITY" \
    --entitlements macos/Runner/DebugProfile.entitlements \
    "$APP"
else
  echo "No signing identity found; leaving the ad-hoc signature in place." >&2
fi

pkill -f lumaberth.app 2>/dev/null || true
sleep 1
open "$APP"
echo "Launched $APP"
