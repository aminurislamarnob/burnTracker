#!/usr/bin/env bash
#
# make-dmg.sh - build BurnTracker (Release) and package an installable .dmg.
# Replaces the old Electron `npm run dist` flow.
#
# Usage:
#   ./scripts/make-dmg.sh
#
# Output:
#   build/BurnTracker-<version>.dmg   (build/ is gitignored)
#
set -euo pipefail

# Resolve repo root (this script's parent directory), regardless of CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="BurnTracker.xcodeproj"
SCHEME="BurnTracker"
CONFIG="Release"
BUILD_DIR="build"
APP_PATH="$BUILD_DIR/Build/Products/$CONFIG/BurnTracker.app"

# Version comes from the built app's Info.plist (MARKETING_VERSION).
echo "==> Building $SCHEME ($CONFIG)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_DIR" \
  clean build

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: build did not produce $APP_PATH" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo 'dev')"
DMG_PATH="$BUILD_DIR/BurnTracker-$VERSION.dmg"
STAGE_DIR="$BUILD_DIR/dmg-stage"

echo "==> Staging disk image contents..."
rm -rf "$STAGE_DIR" "$DMG_PATH"
mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

echo "==> Creating ${DMG_PATH}..."
hdiutil create \
  -volname "Install BurnTracker" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

rm -rf "$STAGE_DIR"

echo "==> Done: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
echo "    Open with: open \"$DMG_PATH\""
