#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$#" -eq 0 ]]; then
  SOURCE_SVG="$ROOT_DIR/docs/assets/dmg-background.svg"
  OUTPUT_PNG="$ROOT_DIR/docs/assets/dmg-background.png"
elif [[ "$#" -eq 2 ]]; then
  SOURCE_SVG="$1"
  OUTPUT_PNG="$2"
else
  echo "usage: $0 [SOURCE_SVG OUTPUT_PNG]" >&2
  exit 2
fi
RENDERER="$ROOT_DIR/scripts/render-dmg-background.swift"
WORK_ROOT="/tmp/KeyLightDMGBackgroundRender-$$"
XCODE_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SCALE=1

if [[ "$(basename "$OUTPUT_PNG")" == *@2x.* ]]; then
  SCALE=2
fi

if [[ -e "$WORK_ROOT" || -L "$WORK_ROOT" ]]; then
  echo "error: temporary render path already exists: $WORK_ROOT" >&2
  exit 1
fi
mkdir -m 700 "$WORK_ROOT"
mkdir -p "$WORK_ROOT/module-cache"

qlmanage -t -s "$((600 * SCALE))" -o "$WORK_ROOT" "$SOURCE_SVG" >/dev/null
THUMBNAIL="$WORK_ROOT/$(basename "$SOURCE_SVG").png"
if [[ ! -f "$THUMBNAIL" ]]; then
  echo "error: Quick Look did not render $THUMBNAIL" >&2
  exit 1
fi

CLANG_MODULE_CACHE_PATH="$WORK_ROOT/module-cache" \
DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
  xcrun swift "$RENDERER" "$THUMBNAIL" "$OUTPUT_PNG" "$SCALE"

METADATA="$(sips -g pixelWidth -g pixelHeight -g dpiWidth -g dpiHeight -g format -g hasAlpha -g profile "$OUTPUT_PNG")"
echo "$METADATA"
echo "$METADATA" | rg -F "pixelWidth: $((600 * SCALE))" >/dev/null
echo "$METADATA" | rg -F "pixelHeight: $((400 * SCALE))" >/dev/null
echo "$METADATA" | rg -F "dpiWidth: $((72 * SCALE)).000" >/dev/null
echo "$METADATA" | rg -F "dpiHeight: $((72 * SCALE)).000" >/dev/null
echo "$METADATA" | rg -F "format: png" >/dev/null
echo "$METADATA" | rg -F "hasAlpha: no" >/dev/null
echo "$METADATA" | rg -i "profile:.*sRGB" >/dev/null
