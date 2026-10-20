#!/usr/bin/env bash
# Release flipswitch: build → sign (Developer ID) → DMG → notarize → staple.
#
# Prereqs:
#   - Apple Developer Program membership, "Developer ID Application" cert in Keychain
#   - One-time notarization credential:
#       xcrun notarytool store-credentials "flipswitch" \
#         --apple-id you@example.com --team-id TEAMID --password app-specific-password
#
# Usage:
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./tools/release.sh [version]
#   # e.g. ./tools/release.sh 1.0.2  → Build/flipswitch.dmg + .sha256

set -euo pipefail
cd "$(dirname "$0")/.."

APP=flipswitch
BUNDLE="Build/$APP.app"
DMG="Build/$APP.dmg"
SIGN_ID="${SIGN_ID:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-flipswitch}"
VERSION="${1:-}"

if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Info.plist
fi

echo "==> Build"
make clean >/dev/null
make >/dev/null

echo "==> Sign app (Developer ID + hardened runtime)"
codesign --force --options runtime --timestamp \
  --sign "$SIGN_ID" "$BUNDLE"
codesign --verify --deep --strict --verbose=2 "$BUNDLE"

echo "==> Create DMG"
rm -f "$DMG" Build/dmg-tmp.dmg
hdiutil create -volname "$APP" -srcfolder "$BUNDLE" \
  -ov -format UDRW Build/dmg-tmp.dmg >/dev/null
# Add /Applications symlink inside the DMG
MNT=$(hdiutil attach Build/dmg-tmp.dmg -nobrowse -mountpoint /Volumes/"$APP" | tail -1 | awk '{print $3}')
ln -sfn /Applications /Volumes/"$APP"/Applications
hdiutil detach "$MNT" -quiet
hdiutil convert Build/dmg-tmp.dmg -format UDZO -o "$DMG" >/dev/null
rm -f Build/dmg-tmp.dmg

echo "==> Sign DMG"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

echo "==> Notarize"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Staple"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Checksum"
shasum -a 256 "$DMG" | tee "$DMG.sha256"

echo "==> Gatekeeper check"
spctl -a -vvv -t open --context context:primary-signature "$DMG" || true
spctl -a -vvv "$BUNDLE" || true

echo "Done: $DMG"
