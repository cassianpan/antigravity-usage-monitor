#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Antigravity Usage Monitor"
APP_BUNDLE="$ROOT_DIR/build/${APP_NAME}.app"
VERSION="${APP_VERSION:-0.1.0}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
DMG_NAME="AntigravityUsageMonitor-${VERSION}-macOS-arm64.dmg"
DMG_PATH="$OUT_DIR/$DMG_NAME"

if [ ! -d "$APP_BUNDLE" ]; then
    "$ROOT_DIR/Scripts/build-app.sh"
fi

mkdir -p "$OUT_DIR"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG_PATH"
echo "==> Creating DMG: $DMG_PATH"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "==> Done: $DMG_PATH"
