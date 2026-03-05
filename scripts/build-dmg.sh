#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/KeyLight.xcodeproj"
SCHEME_NAME="KeyLight"
APP_NAME="KeyLight"
DIST_DIR="$ROOT_DIR/dist"
BUILD_ROOT="$ROOT_DIR/.build/dmg"
DERIVED_DATA_PATH="$BUILD_ROOT/DerivedData"
STAGE_DIR="$BUILD_ROOT/stage"
DMG_BG_ASSET_PATH="$ROOT_DIR/docs/assets/dmg-background.png"
DMG_BG_STAGED_NAME="KeyLightInstallerBackground.png"
ENTITLEMENTS_PATH="$ROOT_DIR/KeyLight/KeyLight.entitlements"

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "error: KeyLight.xcodeproj not found at $PROJECT_PATH" >&2
  exit 1
fi

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  if command -v git >/dev/null 2>&1 && git -C "$ROOT_DIR" describe --tags --abbrev=0 >/dev/null 2>&1; then
    VERSION="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 | sed 's/^v//')"
  else
    VERSION="$(date +%Y.%m.%d)"
  fi
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild is required to build KeyLight.app" >&2
  exit 1
fi

DMG_TOOL=()
CREATE_DMG_BIN=""
if command -v create-dmg >/dev/null 2>&1; then
  CREATE_DMG_BIN="$(command -v create-dmg)"
  DMG_TOOL=("$CREATE_DMG_BIN")
elif command -v npx >/dev/null 2>&1; then
  DMG_TOOL=(npx --yes create-dmg)
else
  echo "error: create-dmg not found. Install with: brew install create-dmg" >&2
  exit 1
fi

echo "==> Cleaning build folders"
mkdir -p "$DIST_DIR" "$BUILD_ROOT"
rm -rf "$DERIVED_DATA_PATH" "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

echo "==> Building $APP_NAME.app (Release)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  SWIFT_VERSION=6 \
  SWIFT_STRICT_CONCURRENCY=complete \
  build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: built app not found at $APP_PATH" >&2
  exit 1
fi

echo "==> Staging app bundle"
cp -R "$APP_PATH" "$STAGE_DIR/"
if [[ "${KEYLIGHT_DMG_HEADLESS:-0}" != "1" ]] && [[ -f "$DMG_BG_ASSET_PATH" ]]; then
  cp "$DMG_BG_ASSET_PATH" "$STAGE_DIR/$APP_NAME.app/Contents/Resources/$DMG_BG_STAGED_NAME"
  # The background image is injected into the app bundle to avoid a visible
  # .background folder in Finder. Re-sign staged app so Gatekeeper integrity
  # checks stay valid in the final DMG.
  if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS_PATH" "$STAGE_DIR/$APP_NAME.app"
  fi
fi

DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
rm -f "$DMG_PATH"

echo "==> Creating DMG: $DMG_PATH"
CREATE_DMG_ARGS=(
  --format UDZO
  --volname "$APP_NAME $VERSION"
  --window-pos 180 120
  --window-size 600 400
  --icon-size 128
  --icon "$APP_NAME.app" 179 150
  --hide-extension "$APP_NAME.app"
  --app-drop-link 439 150
  --no-internet-enable
)

if [[ "${KEYLIGHT_DMG_HEADLESS:-0}" == "1" ]]; then
  CREATE_DMG_ARGS+=(--skip-jenkins)
elif [[ ! -f "$DMG_BG_ASSET_PATH" ]]; then
  echo "warning: DMG background not found at $DMG_BG_ASSET_PATH; using Finder default background"
fi

if [[ -n "$CREATE_DMG_BIN" ]] && [[ "${KEYLIGHT_DMG_HEADLESS:-0}" != "1" ]] && [[ -f "$DMG_BG_ASSET_PATH" ]]; then
  # Use a patched create-dmg copy that resolves support files from Homebrew and
  # sets the background from inside KeyLight.app to avoid a visible .background folder.
  PATCHED_CREATE_DMG="$BUILD_ROOT/create-dmg-no-scroll.sh"
  CREATE_DMG_SUPPORT_DIR="$(cd "$(dirname "$CREATE_DMG_BIN")/../share/create-dmg/support" && pwd)"
  BACKGROUND_CLAUSE="set background picture of opts to file \"$APP_NAME.app:Contents:Resources:$DMG_BG_STAGED_NAME\""
  sed \
    -e "s|SKIP_JENKINS=0|SKIP_JENKINS=0\\nBACKGROUND_CLAUSE='$BACKGROUND_CLAUSE'|" \
    -e "s|CDMG_SUPPORT_DIR=\"\\\$prefix_dir/share/create-dmg/support\"|CDMG_SUPPORT_DIR=\"$CREATE_DMG_SUPPORT_DIR\"|" \
    "$CREATE_DMG_BIN" > "$PATCHED_CREATE_DMG"
  chmod +x "$PATCHED_CREATE_DMG"
  DMG_TOOL=("$PATCHED_CREATE_DMG")
fi

"${DMG_TOOL[@]}" \
  "${CREATE_DMG_ARGS[@]}" \
  "$DMG_PATH" \
  "$STAGE_DIR"

echo "==> Removing staged app bundle to avoid stale launch collisions"
rm -rf "$STAGE_DIR/$APP_NAME.app"

echo "==> Done"
echo "DMG path: $DMG_PATH"
