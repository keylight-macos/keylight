#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/KeyLight.xcodeproj"
SCHEME_NAME="KeyLight"
APP_NAME="KeyLight"
DIST_DIR="$ROOT_DIR/dist"
WORK_ROOT="${KEYLIGHT_DMG_WORK_ROOT:-/tmp/KeyLightDMG}"
BUILD_ROOT="$WORK_ROOT/build"
DERIVED_DATA_PATH="$BUILD_ROOT/DerivedData"
STAGE_DIR="$BUILD_ROOT/stage"
OUTPUT_ROOT="$WORK_ROOT/output"
VERIFY_ROOT="$WORK_ROOT/verify"
VERIFY_MOUNT_POINT="$VERIFY_ROOT/mount"
DMG_BG_ASSET_PATH="$ROOT_DIR/docs/assets/dmg-background.png"
DMG_BG_STAGED_NAME="KeyLightInstallerBackground.png"
ENTITLEMENTS_PATH="$ROOT_DIR/KeyLight/KeyLight.entitlements"
FINAL_DMG_PATH=""
WORK_DMG_PATH=""
ATTACHED_DEVICE=""
EXPECT_CUSTOM_LAYOUT=0
ROOT_DIR_NAME="$(basename "$ROOT_DIR")"
HOME_NAME=""
if [[ -n "${HOME:-}" ]]; then
  HOME_NAME="$(basename "$HOME")"
fi

BANNED_PATTERNS=(
  "/Users/"
  "$ROOT_DIR"
  "$ROOT_DIR_NAME"
  "chatgpt.com"
  "cheekyleo"
  "@users.noreply.github.com"
  "noreply@github.com"
)

if [[ -n "${HOME:-}" ]]; then
  BANNED_PATTERNS+=("$HOME")
fi

if [[ -n "$HOME_NAME" ]]; then
  BANNED_PATTERNS+=("/Users/$HOME_NAME/")
  BANNED_PATTERNS+=("/$HOME_NAME/")
  BANNED_PATTERNS+=(":$HOME_NAME:")
fi

cleanup() {
  local exit_code=$?
  if [[ -n "${ATTACHED_DEVICE:-}" ]]; then
    hdiutil detach "$ATTACHED_DEVICE" >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}

trap cleanup EXIT

log() {
  echo "==> $*"
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: $command_name is required" >&2
    exit 1
  fi
}

sanitize_tree() {
  local path="$1"

  if [[ ! -e "$path" ]]; then
    return
  fi

  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$path" 2>/dev/null || true
  fi

  find "$path" -name '.DS_Store' -delete 2>/dev/null || true
  find "$path" -name '.fseventsd' -prune -exec rm -rf {} + 2>/dev/null || true
}

scan_text_file() {
  local label="$1"
  local file_path="$2"
  local pattern=""

  if [[ ! -f "$file_path" ]]; then
    return
  fi

  for pattern in "${BANNED_PATTERNS[@]}"; do
    [[ -z "$pattern" ]] && continue
    if rg -n -F -- "$pattern" "$file_path" >/dev/null 2>&1; then
      echo "error: found banned pattern '$pattern' in $label" >&2
      rg -n -F -- "$pattern" "$file_path" | head -n 5 >&2 || true
      exit 1
    fi
  done
}

scan_strings_file() {
  local label="$1"
  local source_path="$2"
  local output_path="$3"

  strings "$source_path" > "$output_path" || true
  scan_text_file "$label" "$output_path"
}

scan_binary_tree() {
  local label="$1"
  local target_path="$2"
  local pattern=""

  for pattern in "${BANNED_PATTERNS[@]}"; do
    [[ -z "$pattern" ]] && continue
    if rg -a -n -F -- "$pattern" "$target_path" >/dev/null 2>&1; then
      echo "error: found banned pattern '$pattern' in $label" >&2
      rg -a -n -F -- "$pattern" "$target_path" | head -n 5 >&2 || true
      exit 1
    fi
  done
}

verify_xattrs() {
  local target_path="$1"
  local report_path="$VERIFY_ROOT/app-xattrs.txt"
  local disallowed_attribute=""

  if ! command -v xattr >/dev/null 2>&1; then
    return
  fi

  xattr -lr "$target_path" > "$report_path" 2>/dev/null || true
  for disallowed_attribute in \
    "com.apple.quarantine" \
    "com.apple.lastuseddate#PS" \
    "com.apple.metadata:kMDItemWhereFroms" \
    "com.apple.macl"; do
    if rg -n -F -- "$disallowed_attribute" "$report_path" >/dev/null 2>&1; then
      echo "error: found disallowed xattr '$disallowed_attribute' in mounted app bundle" >&2
      rg -n -F -- "$disallowed_attribute" "$report_path" | head -n 5 >&2 || true
      exit 1
    fi
  done
}

verify_codesign_metadata() {
  local target_path="$1"
  local report_path="$VERIFY_ROOT/codesign.txt"

  codesign -dv --verbose=4 "$target_path" >/dev/null 2> "$report_path"

  if ! rg -n -F -- "Identifier=com.keylight.app" "$report_path" >/dev/null 2>&1; then
    echo "error: expected bundle identifier not found in codesign metadata" >&2
    cat "$report_path" >&2
    exit 1
  fi

  if ! rg -n -F -- "TeamIdentifier=not set" "$report_path" >/dev/null 2>&1; then
    echo "error: expected ad-hoc team identifier metadata not found" >&2
    cat "$report_path" >&2
    exit 1
  fi
}

verify_dmg() {
  local mounted_app_path=""
  local ds_store_strings_path="$VERIFY_ROOT/root-dsstore.strings"
  local dmg_strings_path="$VERIFY_ROOT/dmg.strings"

  rm -rf "$VERIFY_ROOT"
  mkdir -p "$VERIFY_MOUNT_POINT"

  log "Verifying DMG bytes for privacy leaks"
  scan_strings_file "DMG bytes" "$WORK_DMG_PATH" "$dmg_strings_path"

  log "Mounting DMG for bundle verification"
  hdiutil attach -nobrowse -readonly -mountpoint "$VERIFY_MOUNT_POINT" "$WORK_DMG_PATH" > "$VERIFY_ROOT/hdiutil-attach.txt"
  ATTACHED_DEVICE="$(awk '/^\/dev\// {print $1; exit}' "$VERIFY_ROOT/hdiutil-attach.txt")"
  if [[ -z "$ATTACHED_DEVICE" ]]; then
    echo "error: failed to determine mounted DMG device" >&2
    cat "$VERIFY_ROOT/hdiutil-attach.txt" >&2
    exit 1
  fi

  mounted_app_path="$VERIFY_MOUNT_POINT/$APP_NAME.app"
  if [[ ! -d "$mounted_app_path" ]]; then
    echo "error: mounted app bundle not found at $mounted_app_path" >&2
    exit 1
  fi

  if [[ "$EXPECT_CUSTOM_LAYOUT" == "1" ]]; then
    if [[ ! -f "$VERIFY_MOUNT_POINT/.DS_Store" ]]; then
      echo "error: expected DMG Finder metadata (.DS_Store) was not created" >&2
      exit 1
    fi

    scan_strings_file "mounted DMG .DS_Store" "$VERIFY_MOUNT_POINT/.DS_Store" "$ds_store_strings_path"
    for required_marker in "$DMG_BG_STAGED_NAME" "$APP_NAME.app"; do
      if ! rg -n -F -- "$required_marker" "$ds_store_strings_path" >/dev/null 2>&1; then
        echo "error: expected custom DMG marker '$required_marker' not found in mounted .DS_Store" >&2
        exit 1
      fi
    done
  fi

  scan_binary_tree "mounted app bundle" "$mounted_app_path"
  verify_xattrs "$mounted_app_path"
  verify_codesign_metadata "$mounted_app_path"

  hdiutil detach "$ATTACHED_DEVICE" >/dev/null
  ATTACHED_DEVICE=""
}

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

require_command codesign
require_command hdiutil
require_command rg
require_command strip
require_command strings

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

FINAL_DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
WORK_DMG_PATH="$OUTPUT_ROOT/${APP_NAME}-${VERSION}.dmg"

log "Cleaning build folders"
mkdir -p "$DIST_DIR" "$WORK_ROOT"
rm -rf "$BUILD_ROOT" "$OUTPUT_ROOT" "$VERIFY_ROOT" "$FINAL_DMG_PATH"
mkdir -p "$BUILD_ROOT" "$OUTPUT_ROOT"
mkdir -p "$STAGE_DIR"

log "Building $APP_NAME.app (Release)"
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

log "Staging app bundle"
cp -R "$APP_PATH" "$STAGE_DIR/"
sanitize_tree "$STAGE_DIR"
strip -S -x "$STAGE_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME"
if [[ "${KEYLIGHT_DMG_HEADLESS:-0}" != "1" ]] && [[ -f "$DMG_BG_ASSET_PATH" ]]; then
  EXPECT_CUSTOM_LAYOUT=1
  cp "$DMG_BG_ASSET_PATH" "$STAGE_DIR/$APP_NAME.app/Contents/Resources/$DMG_BG_STAGED_NAME"
  sanitize_tree "$STAGE_DIR/$APP_NAME.app/Contents/Resources/$DMG_BG_STAGED_NAME"
fi
# Re-sign after stripping binary symbols and injecting the background asset so
# the staged app bundle stays internally consistent inside the final DMG.
codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS_PATH" "$STAGE_DIR/$APP_NAME.app"
sanitize_tree "$STAGE_DIR"

log "Creating DMG in neutral workspace: $WORK_DMG_PATH"
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
  "$WORK_DMG_PATH" \
  "$STAGE_DIR"

verify_dmg

log "Copying verified DMG to $FINAL_DMG_PATH"
cp "$WORK_DMG_PATH" "$FINAL_DMG_PATH"
if command -v xattr >/dev/null 2>&1; then
  xattr -c "$FINAL_DMG_PATH" 2>/dev/null || true
fi

echo "==> Removing staged app bundle to avoid stale launch collisions"
rm -rf "$STAGE_DIR/$APP_NAME.app"

echo "==> Done"
echo "DMG path: $FINAL_DMG_PATH"
