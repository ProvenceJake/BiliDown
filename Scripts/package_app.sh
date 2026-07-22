#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"

swift build -c "$CONFIGURATION" --arch arm64 --package-path "$ROOT_DIR"
BIN_DIR="$(swift build --show-bin-path -c "$CONFIGURATION" --arch arm64 --package-path "$ROOT_DIR")"

APP_DIR="$ROOT_DIR/build/BiliDown.app"
if [ -e "$APP_DIR" ]; then
    mv "$APP_DIR" "$ROOT_DIR/build/BiliDown.app.backup-$(date +%Y%m%d%H%M%S)"
fi
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/BiliDown" "$APP_DIR/Contents/MacOS/BiliDown"
cp "$ROOT_DIR/Support/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -f "$ROOT_DIR/Support/AppIcon.icns" ]; then
    cp "$ROOT_DIR/Support/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
chmod +x "$APP_DIR/Contents/MacOS/BiliDown"

codesign --force --sign - "$APP_DIR" >/dev/null

echo "$APP_DIR"
