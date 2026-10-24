#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <output-directory>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="$PROJECT_ROOT/build/macos/Build/Products/Release/airbridge_mobile.app"
OUTPUT_DIR="$1"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Flutter macOS app bundle not found: $APP_BUNDLE" >&2
  echo "Run 'flutter build macos --release' from airbridge_mobile first." >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_BUNDLE" "$STAGING_DIR/Airbridge.app"
ln -s /Applications "$STAGING_DIR/Applications"

OUTPUT="$OUTPUT_DIR/Airbridge-macOS.dmg"
hdiutil create \
  -quiet \
  -volname Airbridge \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$OUTPUT"
test -s "$OUTPUT"
echo "Created macOS disk image: $OUTPUT"
