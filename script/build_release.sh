#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Cabinet"
VERSION="${1:-1.1.0}"
BUILD_CONFIGURATION="${CARTRIDGES_BUILD_CONFIGURATION:-release}"

cd "$ROOT_DIR"

# Build the .app bundle (release by default).
./script/build_and_run.sh --build-only

APP_BUNDLE="$ROOT_DIR/../Cabinet.app"

# Stamp the release version into the bundle's Info.plist.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_BUNDLE/Contents/Info.plist"

# Re-sign after modifying the bundle contents.
codesign --force --sign - "$APP_BUNDLE"

# Assemble a distributable DMG.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP_BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="$ROOT_DIR/${APP_NAME}-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "Created $DMG"
