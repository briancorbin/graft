#!/usr/bin/env bash
# Build, Developer ID-sign, notarize, and staple Graft Bar into a distributable
# zip for the Homebrew cask.
#
# Prereqs (one-time, done by you — they need your Apple Developer account):
#   1. A "Developer ID Application" certificate in your login keychain.
#      Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application
#   2. A stored notary credential profile named "graft-notary":
#      xcrun notarytool store-credentials graft-notary \
#        --apple-id you@example.com --team-id <TEAMID> --password <app-specific-password>
#      (or use --key/--key-id/--issuer for an App Store Connect API key)
#
# Usage: scripts/release-app.sh <version>     e.g. scripts/release-app.sh 0.1.1
set -euo pipefail

VERSION="${1:?usage: release-app.sh <version>}"
IDENTITY="${GRAFT_SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${GRAFT_NOTARY_PROFILE:-graft-notary}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Regenerating Xcode project"
xcodegen generate

echo "==> Building Release (Developer ID, hardened runtime, secure timestamp)"
DERIVED="$ROOT/.build-app"
rm -rf "$DERIVED"
xcodebuild -project Graft.xcodeproj -scheme Graft -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build

APP="$DERIVED/Build/Products/Release/Graft.app"
[ -d "$APP" ] || { echo "build did not produce $APP" >&2; exit 1; }

echo "==> Verifying signature + hardened runtime"
codesign --verify --strict --verbose=2 "$APP"
codesign -d --verbose=2 "$APP" 2>&1 | grep -i "runtime" || echo "WARNING: hardened runtime flag not found"

DIST="$ROOT/dist"
mkdir -p "$DIST"
ZIP="$DIST/Graft-$VERSION.zip"

echo "==> Zipping for notarization"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notary service (waits for result)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling the ticket onto the app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Re-zipping the stapled app for distribution"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "==> Done."
echo "    artifact: $ZIP"
echo "    sha256:   $(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo
echo "Next: attach to the v$VERSION release and update the cask sha256."
