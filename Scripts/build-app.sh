#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
ARCHITECTURE="${ARCHITECTURE:-arm64}"
OUTPUT_DIR="$ROOT/dist"
APP_DIR="$OUTPUT_DIR/MacDict.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

BIN_DIR="$(swift build --package-path "$ROOT" -c "$CONFIGURATION" --arch "$ARCHITECTURE" --show-bin-path)"
swift build --package-path "$ROOT" -c "$CONFIGURATION" --arch "$ARCHITECTURE"

cp "$BIN_DIR/MacDict" "$APP_DIR/Contents/MacOS/MacDict"
cp "$ROOT/Info.plist" "$APP_DIR/Contents/Info.plist"

codesign --force --deep --sign - "$APP_DIR"

echo "Built $APP_DIR"
echo "Run with: open '$APP_DIR'"
