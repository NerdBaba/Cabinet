#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Cabinet"
BUILD_CONFIGURATION="${CARTRIDGES_BUILD_CONFIGURATION:-release}"
if [[ "$MODE" == "--debug" ]]; then BUILD_CONFIGURATION="debug"; fi
APP_BUNDLE="$ROOT_DIR/../Cabinet.app"
cd "$ROOT_DIR"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/module-cache"
if [[ "$MODE" != "--build-only" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x CartridgesSwift >/dev/null 2>&1 || true
fi
swift build --configuration "$BUILD_CONFIGURATION" --disable-sandbox --cache-path "$ROOT_DIR/.build/cache"
BUILD_BINARY="$(swift build --configuration "$BUILD_CONFIGURATION" --disable-sandbox --cache-path "$ROOT_DIR/.build/cache" --show-bin-path)/$APP_NAME"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILD_BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR"/Resources/* "$APP_BUNDLE/Contents/Resources/"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Cabinet</string>
<key>CFBundleIdentifier</key><string>dev.cartridges.swift.rebuild</string>
<key>CFBundleName</key><string>Cabinet</string>
<key>CFBundleDisplayName</key><string>Cabinet</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -cr "$APP_BUNDLE"
codesign --force --sign - "$APP_BUNDLE"
case "$MODE" in
  --build-only) ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 1; pgrep -x "$APP_NAME" >/dev/null ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "Cabinet"' ;;
  --telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "dev.cartridges.swift.rebuild"' ;;
  *) echo 'usage: build_and_run.sh [--build-only|--verify|--debug|--logs|--telemetry]' >&2; exit 2 ;;
esac
