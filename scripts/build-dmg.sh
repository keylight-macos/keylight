#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/build-dmg.sh --local VERSION
  ./scripts/build-dmg.sh --preview-local VERSION
  ./scripts/build-dmg.sh --preview-signed VERSION
  ./scripts/build-dmg.sh --side-by-side-local VERSION
  ./scripts/build-dmg.sh --release-unsigned VERSION
  ./scripts/build-dmg.sh --release VERSION

Modes:
  --local    Build an ad-hoc-signed app in an explicitly local, unsigned DMG.
             Its local-only signature relaxes library validation solely so
             the ad-hoc app can load the independently ad-hoc Sparkle binary.
             Output: dist/KeyLight-VERSION-local-unsigned.dmg

  --preview-local
             Build KeyLight Motion Preview.app with an isolated bundle ID.
             The same local-only Sparkle compatibility exception applies.
             Output: dist/KeyLight-VERSION-motion-preview-local-unsigned.dmg

  --preview-signed
             Build the isolated Motion Preview with Developer ID, notarize and
             staple the app, then sign, notarize, and staple its DMG. No
             production update feed or key is embedded.
             Output: dist/KeyLight-VERSION-motion-preview-signed.dmg

  --side-by-side-local
             Build the isolated KeyLight 2.0.app beside KeyLight.app.
             Output: dist/KeyLight-VERSION-side-by-side-local-unsigned.dmg

  --release-unsigned
             Build the normal KeyLight.app / com.keylight.app identity as an
             ad-hoc-signed, unnotarized public release. No update feed or key
             is embedded. Output: dist/KeyLight-VERSION.dmg

  --release  Archive and export with Developer ID, notarize and staple the app,
             then sign, notarize, and staple the DMG.
             Output: dist/KeyLight-VERSION.dmg

Signed packaging environment:
  KEYLIGHT_DEVELOPER_ID_APPLICATION
      Optional exact certificate name when more than one valid Developer ID
      Application identity is installed, for example:
      Developer ID Application: Example Name (TEAMID1234)
  KEYLIGHT_DEVELOPMENT_TEAM
      Optional ten-character team selector. The selected certificate hash and
      Team ID are always derived from the installed Keychain identity.
  KEYLIGHT_BUILD_NUMBER
      Optional positive build number. It must match Shared.xcconfig.
  KEYLIGHT_SPARKLE_FEED_URL
      Optional HTTPS appcast override. Release mode defaults to the stable
      KeyLight GitHub Releases appcast URL.
  KEYLIGHT_SPARKLE_PUBLIC_ED_KEY
      Required base64 Ed25519 public key for release mode.
  KEYLIGHT_SPARKLE_TOOLS_DIR
      Required path to the pinned Sparkle 2.9.5 bin directory containing
      generate_keys, generate_appcast, and sign_update.
  KEYLIGHT_SPARKLE_KEY_ACCOUNT
      Optional Sparkle Keychain account. Defaults to ed25519.
  KEYLIGHT_CLONED_SOURCE_PACKAGES_DIR
      Optional Xcode SourcePackages directory for an already verified local
      cache. Resolution remains restricted to Package.resolved.

Both signed modes require a notarytool keychain profile named
KeyLightNotary. Create it with `xcrun notarytool store-credentials`.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || die "$command_name is required"
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARED_CONFIG_PATH="$ROOT_DIR/Configurations/Shared.xcconfig"

xcconfig_value() {
  local key="$1"
  sed -n -E "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\\1/p" \
    "$SHARED_CONFIG_PATH" | tail -n 1
}

if [[ "$#" -ne 2 ]]; then
  usage >&2
  exit 2
fi

case "$1" in
  --local)
    MODE="local"
    ;;
  --preview-local)
    MODE="preview-local"
    ;;
  --preview-signed)
    MODE="preview-signed"
    ;;
  --side-by-side-local)
    MODE="side-by-side-local"
    ;;
  --release-unsigned)
    MODE="release-unsigned"
    ;;
  --release)
    MODE="release"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

is_signed_mode() {
  [[ "$MODE" == "release" || "$MODE" == "preview-signed" ]]
}

is_release_artifact_mode() {
  [[ "$MODE" == "release" || "$MODE" == "release-unsigned" ]]
}

requires_full_quality_gates() {
  is_signed_mode || [[ "$MODE" == "release-unsigned" ]]
}

VERSION="$2"
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  die "VERSION must contain two or three numeric components (for example 1.1 or 1.1.0)"
fi

CONFIGURED_VERSION="$(xcconfig_value MARKETING_VERSION)"
CONFIGURED_BUILD="$(xcconfig_value CURRENT_PROJECT_VERSION)"
[[ "$VERSION" == "$CONFIGURED_VERSION" ]] || \
  die "VERSION '$VERSION' must match Shared.xcconfig MARKETING_VERSION '$CONFIGURED_VERSION'"

BUILD_NUMBER="${KEYLIGHT_BUILD_NUMBER:-$CONFIGURED_BUILD}"
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  die "KEYLIGHT_BUILD_NUMBER must be a positive integer"
fi
[[ "$BUILD_NUMBER" == "$CONFIGURED_BUILD" ]] || \
  die "KEYLIGHT_BUILD_NUMBER '$BUILD_NUMBER' must match Shared.xcconfig CURRENT_PROJECT_VERSION '$CONFIGURED_BUILD'"

PROJECT_PATH="$ROOT_DIR/KeyLight.xcodeproj"
SCHEME_NAME="KeyLight"
APP_NAME="KeyLight"
PRODUCTION_BUNDLE_ID="com.keylight.app"
LOCAL_BUNDLE_ID="com.keylight.app.debug"
PREVIEW_BUNDLE_ID="com.keylight.app.motionpreview"
SIDE_BY_SIDE_BUNDLE_ID="com.keylight.app.v2"
DIST_DIR="$ROOT_DIR/dist"
DMG_BG_ASSET_PATH="$ROOT_DIR/docs/assets/dmg-background.png"
ENTITLEMENTS_PATH="$ROOT_DIR/KeyLight/KeyLight.entitlements"
PACKAGE_RESOLVED_PATH="$ROOT_DIR/KeyLight.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
PRIVACY_MANIFEST_PATH="$ROOT_DIR/KeyLight/Resources/PrivacyInfo.xcprivacy"
RELEASE_METADATA_GENERATOR="$ROOT_DIR/scripts/generate-release-metadata.swift"
SPARKLE_SIGNATURE_VERIFIER="$ROOT_DIR/scripts/verify-sparkle-signature.swift"
SPARKLE_SIGNATURE_TEST="$ROOT_DIR/scripts/test-update-signature-verifier.swift"
PROJECT_POLICY_VERIFIER="$ROOT_DIR/scripts/verify-project-policy.sh"
FINDER_METADATA_VERIFIER="$ROOT_DIR/scripts/verify-dmg-finder-metadata.swift"
XCODE_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
NOTARY_PROFILE="KeyLightNotary"
DEVELOPER_ID_IDENTITY="${KEYLIGHT_DEVELOPER_ID_APPLICATION:-}"
DEVELOPMENT_TEAM="${KEYLIGHT_DEVELOPMENT_TEAM:-}"
DEVELOPER_ID_CERT_HASH=""
SPARKLE_FEED_URL="${KEYLIGHT_SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_ED_KEY="${KEYLIGHT_SPARKLE_PUBLIC_ED_KEY:-}"
SPARKLE_TOOLS_DIR="${KEYLIGHT_SPARKLE_TOOLS_DIR:-}"
SPARKLE_KEY_ACCOUNT="${KEYLIGHT_SPARKLE_KEY_ACCOUNT:-ed25519}"
CLONED_SOURCE_PACKAGES_DIR="${KEYLIGHT_CLONED_SOURCE_PACKAGES_DIR:-}"
ATTACHED_DEVICE=""
SOURCE_APP_PATH=""
SMOKE_PID=""
EXPECTED_SPARKLE_VERSION="2.9.5"
EXPECTED_SPARKLE_REVISION="79bc9e872948e47877e76f194cb0c8e0412b0b90"
EXPECTED_SIGN_UPDATE_SHA256="bfb52400c3da18bb4c251ac4818c2c2e1e31c2e649a45b31c11109b6e57b34ad"
EXPECTED_GENERATE_APPCAST_SHA256="669a5ed0f90ce06fb1de3e36aba35c5da8b98f66928a185fd4029174071be700"
EXPECTED_GENERATE_KEYS_SHA256="2d18ed3a9c744e58150513d9b2e3c2eb76fd0b9621e3e4678d46dd972547e8fe"

XCODE_PACKAGE_ARGUMENTS=(
  -disableAutomaticPackageResolution
  -onlyUsePackageVersionsFromResolvedFile
)
if [[ -n "$CLONED_SOURCE_PACKAGES_DIR" ]]; then
  XCODE_PACKAGE_ARGUMENTS+=(
    -clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_DIR"
  )
fi

if [[ "$MODE" == "release" ]]; then
  BUNDLE_ID="$PRODUCTION_BUNDLE_ID"
  BUILD_CHANNEL="Production"
  FINAL_DMG_NAME="$APP_NAME-$VERSION.dmg"
  VOLUME_NAME="$APP_NAME $VERSION"
elif [[ "$MODE" == "release-unsigned" ]]; then
  BUNDLE_ID="$PRODUCTION_BUNDLE_ID"
  BUILD_CHANNEL="Unsigned Release"
  FINAL_DMG_NAME="$APP_NAME-$VERSION.dmg"
  VOLUME_NAME="$APP_NAME $VERSION"
elif [[ "$MODE" == "preview-signed" ]]; then
  APP_NAME="KeyLight Motion Preview"
  BUNDLE_ID="$PREVIEW_BUNDLE_ID"
  BUILD_CHANNEL="Motion Preview Signed"
  FINAL_DMG_NAME="KeyLight-$VERSION-motion-preview-signed.dmg"
  VOLUME_NAME="KeyLight Motion Preview"
  DMG_BG_ASSET_PATH="$ROOT_DIR/docs/assets/dmg-background-preview@2x.png"
elif [[ "$MODE" == "preview-local" ]]; then
  APP_NAME="KeyLight Motion Preview"
  BUNDLE_ID="$PREVIEW_BUNDLE_ID"
  BUILD_CHANNEL="Motion Preview Local"
  FINAL_DMG_NAME="KeyLight-$VERSION-motion-preview-local-unsigned.dmg"
  VOLUME_NAME="KeyLight Motion Preview"
  DMG_BG_ASSET_PATH="$ROOT_DIR/docs/assets/dmg-background-preview@2x.png"
elif [[ "$MODE" == "side-by-side-local" ]]; then
  APP_NAME="KeyLight 2.0"
  BUNDLE_ID="$SIDE_BY_SIDE_BUNDLE_ID"
  BUILD_CHANNEL="Side-by-Side Local"
  FINAL_DMG_NAME="KeyLight-$VERSION-side-by-side-local-unsigned.dmg"
  VOLUME_NAME="KeyLight 2.0"
  DMG_BG_ASSET_PATH="$ROOT_DIR/docs/assets/dmg-background-v2@2x.png"
else
  BUNDLE_ID="$LOCAL_BUNDLE_ID"
  BUILD_CHANNEL="Local Debug"
  FINAL_DMG_NAME="$APP_NAME-$VERSION-local-unsigned.dmg"
  VOLUME_NAME="$APP_NAME $VERSION Local"
fi

if [[ "$MODE" == "release" && -z "$SPARKLE_FEED_URL" ]]; then
  SPARKLE_FEED_URL="https://github.com/keylight-macos/keylight/releases/latest/download/appcast.xml"
fi

WORK_ROOT="/tmp/KeyLightDMG-${MODE}-${VERSION}-$$"
BUILD_ROOT="$WORK_ROOT/build"
DERIVED_DATA_PATH="$BUILD_ROOT/DerivedData"
STAGE_DIR="$BUILD_ROOT/stage"
STAGED_APP_PATH="$STAGE_DIR/$APP_NAME.app"
OUTPUT_ROOT="$WORK_ROOT/output"
VERIFY_ROOT="$WORK_ROOT/verify"
VERIFY_MOUNT_POINT="$VERIFY_ROOT/mount"
ARCHIVE_PATH="$BUILD_ROOT/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_ROOT/export"
EXPORT_OPTIONS_PATH="$BUILD_ROOT/ExportOptions.plist"
APP_NOTARY_ZIP="$BUILD_ROOT/$APP_NAME-notary.zip"
AUDIT_ROOT="$WORK_ROOT/audit"
LOCAL_ADHOC_ENTITLEMENTS_PATH="$AUDIT_ROOT/local-adhoc.entitlements"
APP_NOTARY_RESULT="$AUDIT_ROOT/app-notary.json"
APP_NOTARY_LOG="$AUDIT_ROOT/app-notary-log.json"
DMG_NOTARY_RESULT="$AUDIT_ROOT/dmg-notary.json"
DMG_NOTARY_LOG="$AUDIT_ROOT/dmg-notary-log.json"
DMG_BG_FILE_NAME="$(basename "$DMG_BG_ASSET_PATH")"
FINAL_DMG_PATH="$DIST_DIR/$FINAL_DMG_NAME"
WORK_DMG_PATH="$OUTPUT_ROOT/$FINAL_DMG_NAME"
WORK_CHECKSUM_PATH="$OUTPUT_ROOT/$FINAL_DMG_NAME.sha256"
WORK_SBOM_PATH="$OUTPUT_ROOT/KeyLight-$VERSION.spdx.json"
WORK_PROVENANCE_PATH="$OUTPUT_ROOT/KeyLight-$VERSION.provenance.json"
WORK_SPARKLE_SIGNATURE_PATH="$OUTPUT_ROOT/KeyLight-$VERSION.sparkle-signature.txt"
PUBLISH_DMG_PATH="$DIST_DIR/.$FINAL_DMG_NAME.pending.$$"
FINAL_CHECKSUM_PATH="$FINAL_DMG_PATH.sha256"
FINAL_SBOM_PATH="$DIST_DIR/KeyLight-$VERSION.spdx.json"
FINAL_PROVENANCE_PATH="$DIST_DIR/KeyLight-$VERSION.provenance.json"
FINAL_SPARKLE_SIGNATURE_PATH="$DIST_DIR/KeyLight-$VERSION.sparkle-signature.txt"
PUBLISH_CHECKSUM_PATH="$DIST_DIR/.$(basename "$FINAL_CHECKSUM_PATH").pending.$$"
PUBLISH_SBOM_PATH="$DIST_DIR/.$(basename "$FINAL_SBOM_PATH").pending.$$"
PUBLISH_PROVENANCE_PATH="$DIST_DIR/.$(basename "$FINAL_PROVENANCE_PATH").pending.$$"
PUBLISH_SPARKLE_SIGNATURE_PATH="$DIST_DIR/.$(basename "$FINAL_SPARKLE_SIGNATURE_PATH").pending.$$"

[[ ! -e "$WORK_ROOT" && ! -L "$WORK_ROOT" ]] || die "temporary work path already exists: $WORK_ROOT"
[[ ! -e "$PUBLISH_DMG_PATH" && ! -L "$PUBLISH_DMG_PATH" ]] || die "temporary publish path already exists: $PUBLISH_DMG_PATH"

cleanup() {
  local exit_code=$?
  trap - EXIT
  if [[ -n "${SMOKE_PID:-}" ]] && kill -0 "$SMOKE_PID" 2>/dev/null; then
    kill -TERM "$SMOKE_PID" 2>/dev/null || true
    wait "$SMOKE_PID" 2>/dev/null || true
  fi
  if [[ -n "${ATTACHED_DEVICE:-}" ]]; then
    hdiutil detach "$ATTACHED_DEVICE" >/dev/null 2>&1 || true
  fi
  rm -f \
    "$PUBLISH_DMG_PATH" \
    "$PUBLISH_CHECKSUM_PATH" \
    "$PUBLISH_SBOM_PATH" \
    "$PUBLISH_PROVENANCE_PATH" \
    "$PUBLISH_SPARKLE_SIGNATURE_PATH"
  exit "$exit_code"
}

trap cleanup EXIT

sanitize_tree() {
  local path="$1"

  [[ -e "$path" ]] || return

  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$path" 2>/dev/null || true
  fi

  find "$path" -name '.DS_Store' -delete 2>/dev/null || true
  find "$path" -name '.fseventsd' -prune -exec rm -rf {} + 2>/dev/null || true
}

remove_unsigned_release_update_keys() {
  local info_path="$1/Contents/Info.plist"
  local update_key=""

  [[ "$MODE" == "release-unsigned" ]] || return

  for update_key in SUFeedURL SUPublicEDKey; do
    if plutil -extract "$update_key" raw -o - "$info_path" >/dev/null 2>&1; then
      plutil -remove "$update_key" "$info_path"
    fi
  done
}

ROOT_DIR_NAME="$(basename "$ROOT_DIR")"
HOME_NAME=""
GIT_AUTHOR_NAME="$(git -C "$ROOT_DIR" config --get user.name 2>/dev/null || true)"
GIT_AUTHOR_EMAIL="$(git -C "$ROOT_DIR" config --get user.email 2>/dev/null || true)"
if [[ -n "${HOME:-}" ]]; then
  HOME_NAME="$(basename "$HOME")"
fi

BANNED_PATTERNS=(
  "/Users/"
  "$ROOT_DIR"
  "$ROOT_DIR_NAME"
)

if [[ -n "${HOME:-}" ]]; then
  BANNED_PATTERNS+=("$HOME")
fi

if [[ -n "$HOME_NAME" ]]; then
  BANNED_PATTERNS+=("/Users/$HOME_NAME/")
  BANNED_PATTERNS+=("/$HOME_NAME/")
  BANNED_PATTERNS+=(":$HOME_NAME:")
fi

if [[ -n "$GIT_AUTHOR_NAME" ]]; then
  BANNED_PATTERNS+=("$GIT_AUTHOR_NAME")
fi

if [[ -n "$GIT_AUTHOR_EMAIL" ]]; then
  BANNED_PATTERNS+=("$GIT_AUTHOR_EMAIL")
fi

scan_text_file() {
  local label="$1"
  local file_path="$2"
  local pattern=""

  [[ -f "$file_path" ]] || return

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

verify_package_lock() {
  local pin_count=""
  local identity=""
  local version=""
  local revision=""

  [[ -f "$PACKAGE_RESOLVED_PATH" ]] || die "Package.resolved is missing"
  pin_count="$(rg -c '"identity"[[:space:]]*:' "$PACKAGE_RESOLVED_PATH" || true)"
  [[ "$pin_count" == "1" ]] || die "Package.resolved must contain exactly one dependency pin"
  identity="$(plutil -extract pins.0.identity raw -o - "$PACKAGE_RESOLVED_PATH")"
  version="$(plutil -extract pins.0.state.version raw -o - "$PACKAGE_RESOLVED_PATH")"
  revision="$(plutil -extract pins.0.state.revision raw -o - "$PACKAGE_RESOLVED_PATH")"
  [[ "$identity" == "sparkle" ]] || die "unexpected dependency identity '$identity'"
  [[ "$version" == "$EXPECTED_SPARKLE_VERSION" ]] || \
    die "Sparkle must remain exactly pinned to $EXPECTED_SPARKLE_VERSION"
  [[ "$revision" == "$EXPECTED_SPARKLE_REVISION" ]] || \
    die "Sparkle revision does not match the reviewed $EXPECTED_SPARKLE_VERSION source"
}

verify_release_source_state() {
  local configured_version=""
  local configured_build=""
  local tag_name="v$VERSION"
  local tag_type=""

  [[ -z "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]] || \
    die "release mode requires a completely clean source tree"
  git -C "$ROOT_DIR" merge-base --is-ancestor HEAD HEAD >/dev/null || \
    die "could not verify release commit"
  tag_type="$(git -C "$ROOT_DIR" cat-file -t "refs/tags/$tag_name" 2>/dev/null || true)"
  [[ "$tag_type" == "tag" ]] || \
    die "release mode requires annotated tag '$tag_name' at HEAD"
  [[ "$(git -C "$ROOT_DIR" rev-list -n 1 "$tag_name")" == "$(git -C "$ROOT_DIR" rev-parse HEAD)" ]] || \
    die "release tag '$tag_name' does not point to HEAD"

  configured_version="$(xcconfig_value MARKETING_VERSION)"
  configured_build="$(xcconfig_value CURRENT_PROJECT_VERSION)"
  [[ "$configured_version" == "$VERSION" ]] || \
    die "Shared.xcconfig MARKETING_VERSION '$configured_version' does not match '$VERSION'"
  [[ "$configured_build" == "$BUILD_NUMBER" ]] || \
    die "Shared.xcconfig CURRENT_PROJECT_VERSION '$configured_build' does not match '$BUILD_NUMBER'"
}

verify_signed_preview_source_state() {
  local configured_version=""
  local configured_build=""

  [[ -z "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]] || \
    die "signed preview mode requires a completely clean source tree"
  git -C "$ROOT_DIR" merge-base --is-ancestor HEAD HEAD >/dev/null || \
    die "could not verify signed preview commit"

  configured_version="$(xcconfig_value MARKETING_VERSION)"
  configured_build="$(xcconfig_value CURRENT_PROJECT_VERSION)"
  [[ "$configured_version" == "$VERSION" ]] || \
    die "Shared.xcconfig MARKETING_VERSION '$configured_version' does not match '$VERSION'"
  [[ "$configured_build" == "$BUILD_NUMBER" ]] || \
    die "Shared.xcconfig CURRENT_PROJECT_VERSION '$configured_build' does not match '$BUILD_NUMBER'"
}

verify_unsigned_release_source_state() {
  local configured_version=""
  local configured_build=""

  [[ -z "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]] || \
    die "unsigned release mode requires a completely clean source tree"
  git -C "$ROOT_DIR" merge-base --is-ancestor HEAD HEAD >/dev/null || \
    die "could not verify unsigned release commit"

  configured_version="$(xcconfig_value MARKETING_VERSION)"
  configured_build="$(xcconfig_value CURRENT_PROJECT_VERSION)"
  [[ "$configured_version" == "$VERSION" ]] || \
    die "Shared.xcconfig MARKETING_VERSION '$configured_version' does not match '$VERSION'"
  [[ "$configured_build" == "$BUILD_NUMBER" ]] || \
    die "Shared.xcconfig CURRENT_PROJECT_VERSION '$configured_build' does not match '$BUILD_NUMBER'"
}

verify_sparkle_tool() {
  local tool_name="$1"
  local expected_hash="$2"
  local tool_path="$SPARKLE_TOOLS_DIR/$tool_name"
  local actual_hash=""

  [[ -x "$tool_path" ]] || die "pinned Sparkle tool is missing or not executable: $tool_path"
  actual_hash="$(shasum -a 256 "$tool_path" | awk '{print $1}')"
  [[ "$actual_hash" == "$expected_hash" ]] || \
    die "$tool_name does not match the reviewed Sparkle $EXPECTED_SPARKLE_VERSION binary"
}

verify_release_update_configuration() {
  local decoded_key_size=""
  local keychain_public_key=""

  [[ "$SPARKLE_FEED_URL" == https://* ]] || \
    die "KEYLIGHT_SPARKLE_FEED_URL must be an HTTPS URL"
  [[ "$SPARKLE_FEED_URL" != *[[:space:]]* ]] || \
    die "KEYLIGHT_SPARKLE_FEED_URL must not contain whitespace"
  [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]] || \
    die "KEYLIGHT_SPARKLE_PUBLIC_ED_KEY is required"
  decoded_key_size="$(printf '%s' "$SPARKLE_PUBLIC_ED_KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')"
  [[ "$decoded_key_size" == "32" ]] || \
    die "KEYLIGHT_SPARKLE_PUBLIC_ED_KEY must decode to a 32-byte Ed25519 key"
  [[ -d "$SPARKLE_TOOLS_DIR" ]] || \
    die "KEYLIGHT_SPARKLE_TOOLS_DIR must point to the Sparkle $EXPECTED_SPARKLE_VERSION bin directory"

  verify_sparkle_tool sign_update "$EXPECTED_SIGN_UPDATE_SHA256"
  verify_sparkle_tool generate_appcast "$EXPECTED_GENERATE_APPCAST_SHA256"
  verify_sparkle_tool generate_keys "$EXPECTED_GENERATE_KEYS_SHA256"
  keychain_public_key="$(
    "$SPARKLE_TOOLS_DIR/generate_keys" \
      --account "$SPARKLE_KEY_ACCOUNT" \
      -p
  )"
  [[ "$keychain_public_key" == "$SPARKLE_PUBLIC_ED_KEY" ]] || \
    die "the Sparkle Keychain private key does not match KEYLIGHT_SPARKLE_PUBLIC_ED_KEY"
}

run_release_quality_gates() {
  local quality_root="$WORK_ROOT/quality"
  mkdir -p "$quality_root"

  log "Testing signed-update verification failure cases"
  CLANG_MODULE_CACHE_PATH="$quality_root/module-cache" \
  SWIFT_MODULECACHE_PATH="$quality_root/module-cache" \
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
    xcrun swift "$SPARKLE_SIGNATURE_TEST"

  log "Running the complete release test suite"
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcodebuild \
    "${XCODE_PACKAGE_ARGUMENTS[@]}" \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME_NAME" \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$quality_root/tests" \
    SWIFT_VERSION=6 \
    SWIFT_STRICT_CONCURRENCY=complete \
    CODE_SIGNING_ALLOWED=NO \
    test

  log "Running Xcode static analysis"
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcodebuild \
    "${XCODE_PACKAGE_ARGUMENTS[@]}" \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME_NAME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$quality_root/analyze" \
    SWIFT_VERSION=6 \
    SWIFT_STRICT_CONCURRENCY=complete \
    CODE_SIGNING_ALLOWED=NO \
    analyze
}

sign_sparkle_update_archive() {
  local signature_output=""
  local signature=""
  local expected_length=""

  signature_output="$(
    "$SPARKLE_TOOLS_DIR/sign_update" \
      --account "$SPARKLE_KEY_ACCOUNT" \
      "$WORK_DMG_PATH"
  )"
  printf '%s\n' "$signature_output" > "$WORK_SPARKLE_SIGNATURE_PATH"
  signature="$(
    printf '%s\n' "$signature_output" |
      sed -n -E 's/.*sparkle:edSignature="([^"]+)".*/\1/p'
  )"
  expected_length="$(stat -f '%z' "$WORK_DMG_PATH")"
  [[ -n "$signature" ]] || die "Sparkle did not produce an EdDSA archive signature"
  rg -F "length=\"$expected_length\"" "$WORK_SPARKLE_SIGNATURE_PATH" >/dev/null || \
    die "Sparkle signature metadata contains the wrong archive length"
  "$SPARKLE_TOOLS_DIR/sign_update" \
    --account "$SPARKLE_KEY_ACCOUNT" \
    --verify \
    "$WORK_DMG_PATH" \
    "$signature"
  CLANG_MODULE_CACHE_PATH="$WORK_ROOT/module-cache" \
  SWIFT_MODULECACHE_PATH="$WORK_ROOT/module-cache" \
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
    xcrun swift "$SPARKLE_SIGNATURE_VERIFIER" \
      archive \
      "$WORK_DMG_PATH" \
      "$SPARKLE_PUBLIC_ED_KEY" \
      "$signature" \
      "$expected_length"
}

generate_release_metadata() {
  local artifact_sha256=""
  local package_lock_sha256=""
  local source_commit=""
  local xcode_version=""

  artifact_sha256="$(shasum -a 256 "$WORK_DMG_PATH" | awk '{print $1}')"
  package_lock_sha256="$(shasum -a 256 "$PACKAGE_RESOLVED_PATH" | awk '{print $1}')"
  source_commit="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  xcode_version="$(
    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcodebuild -version |
      tr '\n' ' ' |
      sed -E 's/[[:space:]]+$//'
  )"

  CLANG_MODULE_CACHE_PATH="$WORK_ROOT/module-cache" \
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
    xcrun swift "$RELEASE_METADATA_GENERATOR" \
      "$(basename "$WORK_DMG_PATH")" \
      "$artifact_sha256" \
      "$package_lock_sha256" \
      "$VERSION" \
      "$BUILD_NUMBER" \
      "$BUNDLE_ID" \
      "$source_commit" \
      "v$VERSION" \
      "$xcode_version" \
      "$MODE" \
      "$DEVELOPER_ID_CERT_HASH" \
      "$DEVELOPMENT_TEAM" \
      "$WORK_CHECKSUM_PATH" \
      "$WORK_SBOM_PATH" \
      "$WORK_PROVENANCE_PATH"

  rg -F "$artifact_sha256  $(basename "$WORK_DMG_PATH")" "$WORK_CHECKSUM_PATH" >/dev/null || \
    die "release checksum verification failed"
  jq -e . "$WORK_SBOM_PATH" >/dev/null
  jq -e . "$WORK_PROVENANCE_PATH" >/dev/null
}

verify_background_asset() {
  local path="$1"
  local metadata=""
  local scale=1
  local expected_width=600
  local expected_height=400
  local expected_dpi=72

  [[ -f "$path" ]] || die "DMG background not found at $path"
  if [[ "$(basename "$path")" == *@2x.* ]]; then
    scale=2
  fi
  expected_width=$((600 * scale))
  expected_height=$((400 * scale))
  expected_dpi=$((72 * scale))
  metadata="$(sips -g pixelWidth -g pixelHeight -g dpiWidth -g dpiHeight -g format -g hasAlpha -g profile "$path" 2>/dev/null)"
  echo "$metadata" | rg -F "pixelWidth: $expected_width" >/dev/null || die "DMG background must be $expected_width pixels wide"
  echo "$metadata" | rg -F "pixelHeight: $expected_height" >/dev/null || die "DMG background must be $expected_height pixels high"
  echo "$metadata" | rg -F "dpiWidth: $expected_dpi.000" >/dev/null || die "DMG background must use $expected_dpi DPI"
  echo "$metadata" | rg -F "dpiHeight: $expected_dpi.000" >/dev/null || die "DMG background must use $expected_dpi DPI"
  echo "$metadata" | rg -F "format: png" >/dev/null || die "DMG background must be PNG"
  echo "$metadata" | rg -F "hasAlpha: no" >/dev/null || die "DMG background must be opaque"
  echo "$metadata" | rg -i "profile:.*sRGB" >/dev/null || die "DMG background must embed an sRGB profile"
}

verify_xattrs() {
  local target_path="$1"
  local report_path="$VERIFY_ROOT/app-xattrs.txt"
  local disallowed_attribute=""

  command -v xattr >/dev/null 2>&1 || return

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

verify_app_signature() {
  local target_path="$1"
  local report_path="$2"
  local requirement_path="${report_path%.txt}-requirement.txt"

  codesign -dv --verbose=4 "$target_path" >/dev/null 2> "$report_path"
  if ! codesign --verify --deep --strict --verbose=2 "$target_path" >> "$report_path" 2>&1; then
    cat "$report_path" >&2
    die "code-signature verification failed for $target_path"
  fi

  rg -F "Identifier=$BUNDLE_ID" "$report_path" >/dev/null || die "expected bundle identifier not found in code signature"
  rg -F "Runtime Version=" "$report_path" >/dev/null || die "hardened runtime metadata not found in code signature"

  if is_signed_mode; then
    rg -F "TeamIdentifier=$DEVELOPMENT_TEAM" "$report_path" >/dev/null || die "signed app has the wrong TeamIdentifier"
    rg -F "Authority=Developer ID Application:" "$report_path" >/dev/null || die "signed app does not use a Developer ID Application identity"
    rg '^Timestamp=' "$report_path" >/dev/null || die "signed app lacks a secure signing timestamp"
    codesign -d -r- "$target_path" >/dev/null 2> "$requirement_path"
    rg -F "identifier \"$BUNDLE_ID\"" "$requirement_path" >/dev/null || \
      die "signed app designated requirement has the wrong identifier"
    rg -F "certificate leaf[subject.OU] = $DEVELOPMENT_TEAM" "$requirement_path" >/dev/null || \
      die "signed app designated requirement has the wrong Team ID"
    verify_embedded_certificate_hash "$target_path" "app"
  else
    rg -F "Signature=adhoc" "$report_path" >/dev/null || die "local app must be ad-hoc signed"
    rg -F "TeamIdentifier=not set" "$report_path" >/dev/null || die "local app unexpectedly has a signing team"
    if rg -F "Authority=Developer ID Application:" "$report_path" >/dev/null 2>&1; then
      die "local app unexpectedly contains a Developer ID signature"
    fi
  fi
}

adhoc_sign_local_app() {
  local target_path="$1"
  local sparkle_framework="$target_path/Contents/Frameworks/Sparkle.framework"
  local sparkle_version="$sparkle_framework/Versions/Current"
  local nested_code=""
  local nested_components=(
    "$sparkle_version/Updater.app"
    "$sparkle_version/XPCServices/Downloader.xpc"
    "$sparkle_version/XPCServices/Installer.xpc"
    "$sparkle_version/Autoupdate"
  )

  plutil -create xml1 "$LOCAL_ADHOC_ENTITLEMENTS_PATH"
  /usr/libexec/PlistBuddy \
    -c "Add :com.apple.security.cs.disable-library-validation bool true" \
    "$LOCAL_ADHOC_ENTITLEMENTS_PATH"

  # Xcode's embed phase intentionally removes the XCFramework's development
  # Headers, PrivateHeaders, and Modules. That changes Sparkle.framework's
  # sealed resources, so a CODE_SIGNING_ALLOWED=NO build cannot safely reuse
  # the artifact's original signature. Re-sign the pinned framework from the
  # inside out, retaining each helper's identifier and exact entitlement set.
  if [[ -d "$sparkle_framework" ]]; then
    for nested_code in "${nested_components[@]}"; do
      [[ -e "$nested_code" ]] || die "expected embedded Sparkle component is missing: $nested_code"
      codesign \
        --force \
        --sign - \
        --options runtime \
        --preserve-metadata=identifier,entitlements \
        "$nested_code"
      codesign --verify --strict --verbose=2 "$nested_code"
    done

    codesign \
      --force \
      --sign - \
      --options runtime \
      --preserve-metadata=identifier,entitlements \
      "$sparkle_framework"
    codesign --verify --strict --verbose=2 "$sparkle_framework"
  fi

  codesign \
    --force \
    --sign - \
    --options runtime \
    --entitlements "$LOCAL_ADHOC_ENTITLEMENTS_PATH" \
    "$target_path"
}

run_packaged_launch_smoke_test() {
  local target_path="$1"
  local executable_path="$target_path/Contents/MacOS/$APP_NAME"
  local smoke_log="$VERIFY_ROOT/app-launch-smoke.txt"
  local profile_path="$VERIFY_ROOT/app-launch-smoke.profraw"
  local attempt=0
  local smoke_status=0

  [[ -x "$executable_path" ]] || die "packaged launch executable is missing: $executable_path"
  log "Launching the staged app in side-effect-free smoke-test mode"
  rm -f "$profile_path"
  LLVM_PROFILE_FILE="$profile_path" \
  KEYLIGHT_PACKAGE_LAUNCH_SMOKE_TEST=1 \
    "$executable_path" > "$smoke_log" 2>&1 &
  SMOKE_PID=$!

  for ((attempt = 0; attempt < 100; attempt++)); do
    if ! kill -0 "$SMOKE_PID" 2>/dev/null; then
      break
    fi
    sleep 0.05
  done

  if kill -0 "$SMOKE_PID" 2>/dev/null; then
    kill -TERM "$SMOKE_PID" 2>/dev/null || true
    wait "$SMOKE_PID" 2>/dev/null || true
    SMOKE_PID=""
    cat "$smoke_log" >&2 || true
    die "packaged app did not finish its launch smoke test within five seconds"
  fi

  if wait "$SMOKE_PID"; then
    smoke_status=0
  else
    smoke_status=$?
  fi
  SMOKE_PID=""

  if [[ "$smoke_status" -ne 0 ]]; then
    cat "$smoke_log" >&2 || true
    die "packaged app launch smoke test exited with status $smoke_status"
  fi
  if rg -i \
    'Library not loaded|different Team IDs|library validation|fatal dyld' \
    "$smoke_log" >/dev/null 2>&1; then
    cat "$smoke_log" >&2
    die "packaged app launch smoke test reported a dynamic-loader failure"
  fi
  rm -f "$profile_path"
}

verify_entitlement_contract() {
  local target_path="$1"
  local code_path=""
  local report_path=""
  local signature_report=""
  local index=0
  local forbidden_entitlements=(
    "com.apple.security.get-task-allow"
    "com.apple.security.cs.allow-jit"
    "com.apple.security.cs.allow-unsigned-executable-memory"
    "com.apple.security.cs.disable-library-validation"
    "com.apple.security.network.client"
    "com.apple.security.network.server"
  )
  local entitlement=""

  while IFS= read -r code_path; do
    [[ -n "$code_path" && ! -L "$code_path" ]] || continue
    index=$((index + 1))
    report_path="$VERIFY_ROOT/entitlements-$index.plist"
    signature_report="$VERIFY_ROOT/nested-signature-$index.txt"
    codesign -d --entitlements :- "$code_path" > "$report_path" 2>/dev/null || true
    codesign -dv --verbose=4 "$code_path" >/dev/null 2> "$signature_report"
    codesign --verify --strict --verbose=2 "$code_path" >> "$signature_report" 2>&1

    for entitlement in "${forbidden_entitlements[@]}"; do
      if rg -F "$entitlement" "$report_path" >/dev/null 2>&1; then
        if ! is_signed_mode && [[ \
              "$code_path" == "$target_path" && \
              "$entitlement" == \
                "com.apple.security.cs.disable-library-validation" ]]; then
          continue
        fi
        die "forbidden entitlement '$entitlement' found in $code_path"
      fi
    done

    if is_signed_mode; then
      rg -F "TeamIdentifier=$DEVELOPMENT_TEAM" "$signature_report" >/dev/null || \
        die "nested code has the wrong TeamIdentifier: $code_path"
      rg '^Timestamp=' "$signature_report" >/dev/null || \
        die "nested signed code lacks a secure timestamp: $code_path"
    fi
  done < <(
    {
      printf '%s\n' "$target_path"
      find "$target_path/Contents" -type d \
        \( -name '*.app' -o -name '*.framework' -o -name '*.xpc' \) -print
      find "$target_path/Contents" -type f -name '*.dylib' -print
      find "$target_path/Contents" -type f -name 'Autoupdate' -print
    } | sort -u
  )

  codesign -d --entitlements :- "$target_path" > "$VERIFY_ROOT/main-entitlements.plist" 2>/dev/null || true
  if is_signed_mode; then
    if rg -F '<key>' "$VERIFY_ROOT/main-entitlements.plist" >/dev/null 2>&1; then
      die "the Developer ID app executable must retain an empty entitlement set"
    fi
  else
    local main_entitlement_count=""
    local local_library_validation_exception=""
    main_entitlement_count="$(
      rg -o '<key>' "$VERIFY_ROOT/main-entitlements.plist" \
        | wc -l \
        | tr -d '[:space:]'
    )"
    local_library_validation_exception="$(
      /usr/libexec/PlistBuddy \
        -c "Print :com.apple.security.cs.disable-library-validation" \
        "$VERIFY_ROOT/main-entitlements.plist" 2>/dev/null || true
    )"
    [[ "$main_entitlement_count" == "1" && \
       "$local_library_validation_exception" == "true" ]] || \
      die "local ad-hoc app must contain only the Sparkle library-validation compatibility entitlement"
  fi
}

verify_embedded_certificate_hash() {
  local target_path="$1"
  local label="$2"
  local certificate_prefix="$VERIFY_ROOT/$label-signing-cert-"
  local certificate_path="${certificate_prefix}0"
  local embedded_hash=""

  rm -f "${certificate_prefix}"*
  codesign -d --extract-certificates "$certificate_prefix" "$target_path" >/dev/null 2>&1 || \
    die "could not extract the $label signing certificate"
  [[ -f "$certificate_path" ]] || die "$label signing certificate was not extracted"
  embedded_hash="$(shasum -a 1 "$certificate_path" | awk '{print toupper($1)}')"
  rm -f "${certificate_prefix}"*
  [[ "$embedded_hash" == "$DEVELOPER_ID_CERT_HASH" ]] || die "$label was signed by an unexpected certificate"
}

verify_app_binary_contract() {
  local target_path="$1"
  local binary_path="$target_path/Contents/MacOS/$APP_NAME"
  local info_path="$target_path/Contents/Info.plist"
  local resources_path="$target_path/Contents/Resources"
  local metallib_path="$target_path/Contents/Resources/default.metallib"
  local privacy_path="$target_path/Contents/Resources/PrivacyInfo.xcprivacy"
  local sparkle_framework="$target_path/Contents/Frameworks/Sparkle.framework"
  local sparkle_info="$sparkle_framework/Resources/Info.plist"
  local sparkle_binary="$sparkle_framework/Sparkle"
  local build_report="$VERIFY_ROOT/app-build-version.txt"
  local imports_report="$VERIFY_ROOT/app-symbol-imports.txt"
  local metallib_strings="$VERIFY_ROOT/default-metallib.strings"
  local minimum_system_version=""
  local minimum_count=""
  local sparkle_version=""
  local updater_value=""
  local embedded_feed_url=""
  local embedded_public_key=""
  local embedded_build_channel=""

  minimum_system_version="$(plutil -extract LSMinimumSystemVersion raw -o - "$info_path")"
  [[ "$minimum_system_version" == "14.0" ]] || die "mounted app minimum system version is '$minimum_system_version', expected 14.0"
  embedded_build_channel="$(plutil -extract KeyLightBuildChannel raw -o - "$info_path")"
  [[ "$embedded_build_channel" == "$BUILD_CHANNEL" ]] || \
    die "mounted app build channel '$embedded_build_channel' does not match '$BUILD_CHANNEL'"

  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcrun vtool -show-build "$binary_path" > "$build_report"
  minimum_count="$(rg -c '^    minos 14\.0$' "$build_report" || true)"
  [[ "$minimum_count" == "2" ]] || die "expected macOS 14.0 minimum on both universal slices"

  nm -m "$binary_path" > "$imports_report"
  # System Glass and the shared surface engine use SwiftUI's custom-Shape APIs
  # so the material boundary can be a flat bell rather than
  # NSGlassEffectView's rounded rectangle. Every macOS 26-only symbol must
  # remain weak imported so the universal binary still launches on macOS 14/15.
  rg -F 'weak external _$s7SwiftUI20GlassEffectContainerV7spacing7content' "$imports_report" >/dev/null || \
    die "SwiftUI GlassEffectContainer is not weak imported"
  rg -F 'weak external _$s7SwiftUI4ViewPAAE11glassEffect_2in' "$imports_report" >/dev/null || \
    die "SwiftUI custom-shape glassEffect is not weak imported"
  rg -F 'weak external _$s7SwiftUI5GlassV5clearACvgZ' "$imports_report" >/dev/null || \
    die "SwiftUI clear glass material is not weak imported"

  [[ -f "$metallib_path" ]] || \
    die "precompiled Physical Refraction default.metallib is missing"
  strings "$metallib_path" > "$metallib_strings"
  rg -F 'keyLightRefractionVertex' "$metallib_strings" >/dev/null || \
    die "Physical Refraction vertex entry point is missing"
  rg -F 'keyLightRefractionFragment' "$metallib_strings" >/dev/null || \
    die "Physical Refraction fragment entry point is missing"
  if find "$resources_path" -type f -name '*.metal' -print -quit | rg . >/dev/null; then
    die "raw Metal shader source must not ship in the app bundle"
  fi

  [[ -f "$privacy_path" ]] || die "PrivacyInfo.xcprivacy is missing from app resources"
  plutil -lint "$privacy_path" >/dev/null
  rg -F 'NSPrivacyAccessedAPICategoryFileTimestamp' "$privacy_path" >/dev/null || \
    die "privacy manifest lacks the user-selected file metadata declaration"
  rg -F 'NSPrivacyAccessedAPICategorySystemBootTime' "$privacy_path" >/dev/null || \
    die "privacy manifest lacks the monotonic clock declaration"
  rg -F 'NSPrivacyAccessedAPICategoryUserDefaults' "$privacy_path" >/dev/null || \
    die "privacy manifest lacks the local settings declaration"
  [[ "$(plutil -extract NSPrivacyTracking raw -o - "$privacy_path")" == "false" ]] || \
    die "privacy manifest unexpectedly enables tracking"

  [[ -d "$sparkle_framework" ]] || die "Sparkle.framework is missing"
  sparkle_version="$(plutil -extract CFBundleShortVersionString raw -o - "$sparkle_info")"
  [[ "$sparkle_version" == "$EXPECTED_SPARKLE_VERSION" ]] || \
    die "bundled Sparkle version '$sparkle_version' is not $EXPECTED_SPARKLE_VERSION"
  [[ " $(lipo -archs "$sparkle_binary") " == *" arm64 "* ]] || \
    die "bundled Sparkle framework is missing arm64"
  [[ " $(lipo -archs "$sparkle_binary") " == *" x86_64 "* ]] || \
    die "bundled Sparkle framework is missing x86_64"

  for updater_value in \
    SUEnableAutomaticChecks:false \
    SUAutomaticallyUpdate:false \
    SUSendProfileInfo:false \
    SUVerifyUpdateBeforeExtraction:true \
    SURequireSignedFeed:true; do
    local updater_key="${updater_value%%:*}"
    local expected_value="${updater_value##*:}"
    [[ "$(plutil -extract "$updater_key" raw -o - "$info_path")" == "$expected_value" ]] || \
      die "updater policy '$updater_key' is not '$expected_value'"
  done
  [[ "$(plutil -extract SUSignedFeedFailureExpirationInterval raw -o - "$info_path")" == "0" ]] || \
    die "signed feed failures must fail closed without expiration"

  if [[ "$MODE" == "release" ]]; then
    [[ "$(plutil -extract SUFeedURL raw -o - "$info_path")" == "$SPARKLE_FEED_URL" ]] || \
      die "release app contains the wrong Sparkle feed URL"
    [[ "$(plutil -extract SUPublicEDKey raw -o - "$info_path")" == "$SPARKLE_PUBLIC_ED_KEY" ]] || \
      die "release app contains the wrong Sparkle public key"
  elif [[ "$MODE" == "release-unsigned" ]]; then
    if plutil -extract SUFeedURL raw -o - "$info_path" >/dev/null 2>&1; then
      die "unsigned release app must not contain a Sparkle feed key"
    fi
    if plutil -extract SUPublicEDKey raw -o - "$info_path" >/dev/null 2>&1; then
      die "unsigned release app must not contain a Sparkle public-key entry"
    fi
  else
    embedded_feed_url="$(plutil -extract SUFeedURL raw -o - "$info_path" 2>/dev/null || true)"
    embedded_public_key="$(plutil -extract SUPublicEDKey raw -o - "$info_path" 2>/dev/null || true)"
    [[ -z "$embedded_feed_url" ]] || \
      die "local preview unexpectedly contains a production update feed"
    [[ -z "$embedded_public_key" ]] || \
      die "local preview unexpectedly contains a production update key"
  fi
}

verify_release_credentials() {
  local identities=""
  local candidates=""
  local selected=""
  local candidate_count=""
  local requested_identity="$DEVELOPER_ID_IDENTITY"
  local requested_team="$DEVELOPMENT_TEAM"

  if [[ -n "$requested_identity" && "$requested_identity" != "Developer ID Application:"* ]]; then
    die "KEYLIGHT_DEVELOPER_ID_APPLICATION must name a Developer ID Application certificate"
  fi
  if [[ -n "$requested_team" && ! "$requested_team" =~ ^[A-Z0-9]{10}$ ]]; then
    die "KEYLIGHT_DEVELOPMENT_TEAM must be a ten-character team identifier"
  fi

  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  candidates="$(echo "$identities" | rg '^[[:space:]]*[0-9]+\) [A-F0-9]+ "Developer ID Application:' || true)"

  if [[ -n "$requested_identity" ]]; then
    candidates="$(echo "$candidates" | rg -F -- "\"$requested_identity\"" || true)"
  fi
  if [[ -n "$requested_team" ]]; then
    candidates="$(echo "$candidates" | rg -F -- "($requested_team)\"" || true)"
  fi

  candidate_count="$(echo "$candidates" | rg -c . || true)"
  candidate_count="${candidate_count:-0}"
  [[ "$candidate_count" != "0" ]] || die "no matching Developer ID Application identity is available in the keychain"
  [[ "$candidate_count" == "1" ]] || \
    die "multiple Developer ID Application identities match; select one with KEYLIGHT_DEVELOPER_ID_APPLICATION or KEYLIGHT_DEVELOPMENT_TEAM"

  selected="$candidates"
  DEVELOPER_ID_CERT_HASH="$(echo "$selected" | sed -E 's/^[[:space:]]*[0-9]+\) ([A-F0-9]+) ".*$/\1/')"
  DEVELOPER_ID_IDENTITY="$(echo "$selected" | sed -E 's/^[[:space:]]*[0-9]+\) [A-F0-9]+ "(.*)"$/\1/')"
  DEVELOPMENT_TEAM="$(echo "$DEVELOPER_ID_IDENTITY" | sed -E 's/^.*\(([A-Z0-9]{10})\)$/\1/')"

  [[ "$DEVELOPER_ID_CERT_HASH" =~ ^[A-F0-9]{40}$ ]] || die "could not derive the Developer ID certificate hash"
  [[ "$DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]] || die "could not derive the Apple Developer Team ID"
  if [[ -n "$requested_team" && "$requested_team" != "$DEVELOPMENT_TEAM" ]]; then
    die "selected Developer ID identity does not match KEYLIGHT_DEVELOPMENT_TEAM"
  fi

  security find-generic-password \
    -a "$NOTARY_PROFILE" \
    -s "com.apple.gke.notary.tool" >/dev/null 2>&1 || \
    die "notarytool keychain profile '$NOTARY_PROFILE' is not available"
}

submit_for_notarization() {
  local artifact_path="$1"
  local result_path="$2"
  local label="$3"
  local log_path="$4"
  local status=""
  local submission_id=""

  log "Submitting $label for notarization"
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcrun notarytool submit \
    "$artifact_path" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json > "$result_path"

  status="$(plutil -extract status raw -o - "$result_path" 2>/dev/null || true)"
  if [[ "$status" != "Accepted" ]]; then
    cat "$result_path" >&2
    die "$label notarization status was '${status:-unknown}', expected Accepted"
  fi

  submission_id="$(plutil -extract id raw -o - "$result_path" 2>/dev/null || true)"
  [[ -n "$submission_id" ]] || die "$label notarization result omitted its submission ID"
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcrun notarytool log \
    "$submission_id" \
    --keychain-profile "$NOTARY_PROFILE" \
    "$log_path"
  [[ -s "$log_path" ]] || die "$label notarization log was not downloaded"
  if rg -i '"severity"[[:space:]]*:[[:space:]]*"error"' "$log_path" >/dev/null; then
    cat "$log_path" >&2
    die "$label notarization log contains an error despite acceptance"
  fi
}

verify_root_contents() {
  local entry=""
  local name=""

  while IFS= read -r entry; do
    name="${entry##*/}"
    case "$name" in
      .background|.DS_Store|Applications|"$APP_NAME.app")
        ;;
      *)
        die "unexpected item at DMG root: $name"
        ;;
    esac
  done < <(find "$VERIFY_MOUNT_POINT" -mindepth 1 -maxdepth 1 -print)

  [[ -d "$VERIFY_MOUNT_POINT/$APP_NAME.app" ]] || die "mounted app bundle is missing"
  [[ -L "$VERIFY_MOUNT_POINT/Applications" ]] || die "Applications drop link is missing"
  [[ "$(readlink "$VERIFY_MOUNT_POINT/Applications")" == "/Applications" ]] || die "Applications drop link has the wrong destination"
  [[ -f "$VERIFY_MOUNT_POINT/.DS_Store" ]] || die "Finder layout metadata is missing"
  [[ -f "$VERIFY_MOUNT_POINT/.background/$DMG_BG_FILE_NAME" ]] || die "supported create-dmg background is missing"

  if find "$VERIFY_MOUNT_POINT/.background" -mindepth 1 -maxdepth 1 ! -name "$DMG_BG_FILE_NAME" -print -quit | rg . >/dev/null; then
    die "unexpected item in the DMG .background directory"
  fi
}

verify_dmg_signature_mode() {
  local target_path="$1"
  local report_path="$VERIFY_ROOT/dmg-codesign.txt"

  if is_signed_mode; then
    codesign -dv --verbose=4 "$target_path" >/dev/null 2> "$report_path"
    codesign --verify --strict --verbose=2 "$target_path" >> "$report_path" 2>&1
    rg -F "TeamIdentifier=$DEVELOPMENT_TEAM" "$report_path" >/dev/null || die "signed DMG has the wrong TeamIdentifier"
    rg -F "Authority=Developer ID Application:" "$report_path" >/dev/null || die "signed DMG does not use a Developer ID Application identity"
    verify_embedded_certificate_hash "$target_path" "dmg"
    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcrun stapler validate "$target_path"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$target_path"
  else
    if codesign -dv "$target_path" >/dev/null 2>&1; then
      die "local DMG unexpectedly has a code signature"
    fi
    echo "Local DMG intentionally has no Developer ID signature or notarization ticket." > "$report_path"
  fi
}

verify_dmg() {
  local target_path="$1"
  local mounted_app_path=""
  local app_version=""
  local app_build_number=""
  local architectures=""
  local ds_store_hex=""
  local app_name_utf16_hex=""
  local background_name_utf16_hex=""
  local app_bundle_name=""
  local app_display_name=""
  local app_executable_name=""
  local ds_store_strings_path="$VERIFY_ROOT/root-dsstore.strings"
  local dmg_strings_path="$VERIFY_ROOT/dmg.strings"

  rm -rf "$VERIFY_ROOT"
  mkdir -p "$VERIFY_MOUNT_POINT"

  verify_dmg_signature_mode "$target_path"

  log "Verifying DMG bytes for privacy leaks"
  scan_strings_file "DMG bytes" "$target_path" "$dmg_strings_path"

  log "Mounting DMG read-only for bundle and layout verification"
  hdiutil attach -nobrowse -readonly -mountpoint "$VERIFY_MOUNT_POINT" "$target_path" > "$VERIFY_ROOT/hdiutil-attach.txt"
  ATTACHED_DEVICE="$(awk '/^\/dev\// {print $1; exit}' "$VERIFY_ROOT/hdiutil-attach.txt")"
  if [[ -z "$ATTACHED_DEVICE" ]]; then
    cat "$VERIFY_ROOT/hdiutil-attach.txt" >&2
    die "failed to determine mounted DMG device"
  fi

  verify_root_contents
  verify_background_asset "$VERIFY_MOUNT_POINT/.background/$DMG_BG_FILE_NAME"

  scan_strings_file "mounted DMG .DS_Store" "$VERIFY_MOUNT_POINT/.DS_Store" "$ds_store_strings_path"
  rg -F "$DMG_BG_FILE_NAME" "$ds_store_strings_path" >/dev/null || die "Finder background marker is missing from .DS_Store"
  CLANG_MODULE_CACHE_PATH="$WORK_ROOT/module-cache" \
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
    xcrun swift "$FINDER_METADATA_VERIFIER" \
      "$VERIFY_MOUNT_POINT/.DS_Store" 600 432 112 14

  # Finder stores icon locations as UTF-16 names followed by Iloc blobs. Check
  # the exact create-dmg coordinates without relying on `strings`, which does
  # not expose the UTF-16 app name on every macOS release.
  ds_store_hex="$(xxd -p "$VERIFY_MOUNT_POINT/.DS_Store" | tr -d '\n')"
  app_name_utf16_hex="$(printf '%s' "$APP_NAME.app" | iconv -f UTF-8 -t UTF-16BE | xxd -p | tr -d '\n')"
  background_name_utf16_hex="$(printf '%s' ".background" | iconv -f UTF-8 -t UTF-16BE | xxd -p | tr -d '\n')"
  echo "$ds_store_hex" | rg -F "${app_name_utf16_hex}496c6f63626c6f6200000010000000a5000000cd" >/dev/null || \
    die "$APP_NAME.app is not positioned at (165, 205)"
  echo "$ds_store_hex" | rg -F "004100700070006c00690063006100740069006f006e0073496c6f63626c6f6200000010000001b3000000cd" >/dev/null || \
    die "Applications is not positioned at (435, 205)"
  echo "$ds_store_hex" | rg -F "${background_name_utf16_hex}496c6f63626c6f620000001000000dac00000064" >/dev/null || \
    die ".background is not parked outside the resizable Finder canvas"

  mounted_app_path="$VERIFY_MOUNT_POINT/$APP_NAME.app"
  if find "$mounted_app_path" -name 'KeyLightInstallerBackground.png' -print -quit | rg . >/dev/null; then
    die "installer-only artwork leaked into the installed app bundle"
  fi

  app_version="$(plutil -extract CFBundleShortVersionString raw -o - "$mounted_app_path/Contents/Info.plist")"
  [[ "$app_version" == "$VERSION" ]] || die "mounted app version '$app_version' does not match requested version '$VERSION'"
  app_build_number="$(plutil -extract CFBundleVersion raw -o - "$mounted_app_path/Contents/Info.plist")"
  [[ "$app_build_number" == "$BUILD_NUMBER" ]] || die "mounted app build '$app_build_number' does not match requested build '$BUILD_NUMBER'"
  app_bundle_name="$(plutil -extract CFBundleName raw -o - "$mounted_app_path/Contents/Info.plist")"
  [[ "$app_bundle_name" == "$APP_NAME" ]] || die "mounted app bundle name '$app_bundle_name' does not match '$APP_NAME'"
  app_display_name="$(plutil -extract CFBundleDisplayName raw -o - "$mounted_app_path/Contents/Info.plist")"
  [[ "$app_display_name" == "$APP_NAME" ]] || die "mounted app display name '$app_display_name' does not match '$APP_NAME'"
  app_executable_name="$(plutil -extract CFBundleExecutable raw -o - "$mounted_app_path/Contents/Info.plist")"
  [[ "$app_executable_name" == "$APP_NAME" ]] || die "mounted app executable '$app_executable_name' does not match '$APP_NAME'"

  architectures="$(lipo -archs "$mounted_app_path/Contents/MacOS/$APP_NAME")"
  [[ " $architectures " == *" arm64 "* ]] || die "mounted app is missing arm64"
  [[ " $architectures " == *" x86_64 "* ]] || die "mounted app is missing x86_64"

  scan_binary_tree "mounted app bundle" "$mounted_app_path"
  verify_xattrs "$mounted_app_path"
  verify_app_signature "$mounted_app_path" "$VERIFY_ROOT/app-codesign.txt"
  verify_entitlement_contract "$mounted_app_path"
  verify_app_binary_contract "$mounted_app_path"

  if is_signed_mode; then
    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcrun stapler validate "$mounted_app_path"
    spctl --assess --type execute --verbose=4 "$mounted_app_path"
  fi

  hdiutil detach "$ATTACHED_DEVICE" >/dev/null
  ATTACHED_DEVICE=""
}

[[ -d "$PROJECT_PATH" ]] || die "KeyLight.xcodeproj not found at $PROJECT_PATH"
[[ -f "$ENTITLEMENTS_PATH" ]] || die "entitlements file not found at $ENTITLEMENTS_PATH"
[[ -f "$PACKAGE_RESOLVED_PATH" ]] || die "Package.resolved not found at $PACKAGE_RESOLVED_PATH"
[[ -f "$SHARED_CONFIG_PATH" ]] || die "Shared.xcconfig not found at $SHARED_CONFIG_PATH"
[[ -f "$PRIVACY_MANIFEST_PATH" ]] || die "privacy manifest not found at $PRIVACY_MANIFEST_PATH"
[[ -f "$RELEASE_METADATA_GENERATOR" ]] || die "release metadata generator not found at $RELEASE_METADATA_GENERATOR"
[[ -f "$SPARKLE_SIGNATURE_VERIFIER" ]] || die "Sparkle signature verifier not found at $SPARKLE_SIGNATURE_VERIFIER"
[[ -f "$SPARKLE_SIGNATURE_TEST" ]] || die "Sparkle signature verifier test not found at $SPARKLE_SIGNATURE_TEST"
[[ -x "$PROJECT_POLICY_VERIFIER" ]] || die "project policy verifier not found at $PROJECT_POLICY_VERIFIER"
[[ -f "$FINDER_METADATA_VERIFIER" ]] || die "Finder metadata verifier not found at $FINDER_METADATA_VERIFIER"
[[ -d "$XCODE_DEVELOPER_DIR" ]] || die "Xcode developer directory not found at $XCODE_DEVELOPER_DIR"

require_command awk
require_command base64
require_command codesign
require_command cmp
require_command create-dmg
require_command ditto
require_command file
require_command find
require_command git
require_command hdiutil
require_command iconv
require_command jq
require_command lipo
require_command nm
require_command plutil
require_command rg
require_command security
require_command sed
require_command shasum
require_command sips
require_command spctl
require_command stat
require_command strings
require_command strip
require_command tr
require_command wc
require_command xxd
require_command xcrun
require_command xcodebuild

[[ "$(create-dmg --version)" == "create-dmg 1.2.3" ]] || \
  die "create-dmg 1.2.3 is required for the verified Finder layout"
XCODE_MAJOR_VERSION="$(DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcodebuild -version | awk 'NR == 1 {split($2, version, "."); print version[1]}')"
[[ "$XCODE_MAJOR_VERSION" =~ ^[0-9]+$ && "$XCODE_MAJOR_VERSION" -ge 26 ]] || \
  die "Xcode 26 or newer is required to package the native glass effects"

verify_background_asset "$DMG_BG_ASSET_PATH"
verify_package_lock
"$PROJECT_POLICY_VERIFIER"

if [[ "${KEYLIGHT_OVERWRITE:-0}" != "1" ]]; then
  artifacts_to_protect=("$FINAL_DMG_PATH" "$FINAL_CHECKSUM_PATH")
  if is_release_artifact_mode; then
    artifacts_to_protect+=(
      "$FINAL_SBOM_PATH"
      "$FINAL_PROVENANCE_PATH"
    )
    if [[ "$MODE" == "release" ]]; then
      artifacts_to_protect+=("$FINAL_SPARKLE_SIGNATURE_PATH")
    fi
  fi
  for protected_artifact in "${artifacts_to_protect[@]}"; do
    [[ ! -e "$protected_artifact" ]] || \
      die "refusing to overwrite existing artifact at $protected_artifact (remove it or set KEYLIGHT_OVERWRITE=1 intentionally)"
  done
fi

if is_signed_mode; then
  if [[ "$MODE" == "release" ]]; then
    verify_release_source_state
    verify_release_update_configuration
  else
    verify_signed_preview_source_state
  fi
  verify_release_credentials
fi
if [[ "$MODE" == "release-unsigned" ]]; then
  verify_unsigned_release_source_state
fi

log "Preparing isolated packaging workspace"
mkdir -p "$DIST_DIR"
mkdir -m 700 "$WORK_ROOT"
mkdir -p "$BUILD_ROOT" "$OUTPUT_ROOT" "$STAGE_DIR" "$VERIFY_ROOT" "$AUDIT_ROOT" "$WORK_ROOT/module-cache"

if requires_full_quality_gates; then
  run_release_quality_gates
fi

if is_signed_mode; then
  log "Archiving $APP_NAME.app with Developer ID"
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcodebuild \
    -quiet \
    "${XCODE_PACKAGE_ARGUMENTS[@]}" \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME_NAME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH" \
    SWIFT_VERSION=6 \
    SWIFT_STRICT_CONCURRENCY=complete \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    PRODUCT_NAME="$APP_NAME" \
    KEYLIGHT_BUILD_CHANNEL="$BUILD_CHANNEL" \
    KEYLIGHT_SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
    KEYLIGHT_SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$DEVELOPER_ID_CERT_HASH" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    archive

  plutil -create xml1 "$EXPORT_OPTIONS_PATH"
  plutil -insert method -string developer-id "$EXPORT_OPTIONS_PATH"
  plutil -insert destination -string export "$EXPORT_OPTIONS_PATH"
  plutil -insert signingStyle -string manual "$EXPORT_OPTIONS_PATH"
  plutil -insert signingCertificate -string "$DEVELOPER_ID_CERT_HASH" "$EXPORT_OPTIONS_PATH"
  plutil -insert teamID -string "$DEVELOPMENT_TEAM" "$EXPORT_OPTIONS_PATH"
  plutil -insert stripSwiftSymbols -bool true "$EXPORT_OPTIONS_PATH"

  log "Exporting Developer ID app"
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PATH"

  SOURCE_APP_PATH="$EXPORT_PATH/$APP_NAME.app"
else
  log "Building $APP_NAME.app for a local unsigned installer"
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcodebuild \
    -quiet \
    "${XCODE_PACKAGE_ARGUMENTS[@]}" \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME_NAME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    SWIFT_VERSION=6 \
    SWIFT_STRICT_CONCURRENCY=complete \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    PRODUCT_NAME="$APP_NAME" \
    KEYLIGHT_BUILD_CHANNEL="$BUILD_CHANNEL" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

  SOURCE_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/$APP_NAME.app"
fi

[[ -d "$SOURCE_APP_PATH" ]] || die "built app not found at $SOURCE_APP_PATH"

log "Staging app bundle"
ditto "$SOURCE_APP_PATH" "$STAGED_APP_PATH"
sanitize_tree "$STAGED_APP_PATH"
remove_unsigned_release_update_keys "$STAGED_APP_PATH"

if is_signed_mode; then
  verify_app_signature "$STAGED_APP_PATH" "$VERIFY_ROOT/pre-notary-app-codesign.txt"
  ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP_PATH" "$APP_NOTARY_ZIP"
  submit_for_notarization \
    "$APP_NOTARY_ZIP" \
    "$APP_NOTARY_RESULT" \
    "app" \
    "$APP_NOTARY_LOG"
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcrun stapler staple "$STAGED_APP_PATH"
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcrun stapler validate "$STAGED_APP_PATH"
else
  strip -S -x "$STAGED_APP_PATH/Contents/MacOS/$APP_NAME"
  adhoc_sign_local_app "$STAGED_APP_PATH"
fi

verify_app_signature "$STAGED_APP_PATH" "$VERIFY_ROOT/staged-app-codesign.txt"
verify_entitlement_contract "$STAGED_APP_PATH"
run_packaged_launch_smoke_test "$STAGED_APP_PATH"

log "Creating professional drag-to-Applications DMG"
create-dmg \
  --format UDZO \
  --volname "$VOLUME_NAME" \
  --background "$DMG_BG_ASSET_PATH" \
  --window-pos 180 120 \
  --window-size 600 432 \
  --text-size 14 \
  --icon-size 112 \
  --icon "$APP_NAME.app" 165 205 \
  --icon ".background" 3500 100 \
  --hide-extension "$APP_NAME.app" \
  --app-drop-link 435 205 \
  --no-internet-enable \
  "$WORK_DMG_PATH" \
  "$STAGE_DIR"

[[ -f "$WORK_DMG_PATH" ]] || die "create-dmg did not produce $WORK_DMG_PATH"

if is_signed_mode; then
  log "Signing Developer ID DMG"
  codesign \
    --force \
    --sign "$DEVELOPER_ID_CERT_HASH" \
    --identifier "$BUNDLE_ID.dmg" \
    --timestamp \
    "$WORK_DMG_PATH"
  submit_for_notarization \
    "$WORK_DMG_PATH" \
    "$DMG_NOTARY_RESULT" \
    "DMG" \
    "$DMG_NOTARY_LOG"
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcrun stapler staple "$WORK_DMG_PATH"
  if [[ "$MODE" == "release" ]]; then
    log "Signing the final notarized update archive with Sparkle EdDSA"
    sign_sparkle_update_archive
  fi
else
  if command -v xattr >/dev/null 2>&1; then
    xattr -c "$WORK_DMG_PATH" 2>/dev/null || true
  fi
fi

verify_dmg "$WORK_DMG_PATH"

if is_release_artifact_mode; then
  log "Generating checksum, SPDX SBOM, and build provenance"
  generate_release_metadata
else
  log "Generating installer checksum"
  (
    cd "$OUTPUT_ROOT"
    shasum -a 256 "$FINAL_DMG_NAME" > "$FINAL_DMG_NAME.sha256"
  )
fi

log "Publishing verified installer atomically to $FINAL_DMG_PATH"
ditto "$WORK_DMG_PATH" "$PUBLISH_DMG_PATH"
cmp -s "$WORK_DMG_PATH" "$PUBLISH_DMG_PATH" || die "published installer bytes differ from the verified artifact"
ditto "$WORK_CHECKSUM_PATH" "$PUBLISH_CHECKSUM_PATH"
cmp -s "$WORK_CHECKSUM_PATH" "$PUBLISH_CHECKSUM_PATH" || die "published checksum bytes differ"
if is_release_artifact_mode; then
  ditto "$WORK_SBOM_PATH" "$PUBLISH_SBOM_PATH"
  ditto "$WORK_PROVENANCE_PATH" "$PUBLISH_PROVENANCE_PATH"
  cmp -s "$WORK_SBOM_PATH" "$PUBLISH_SBOM_PATH" || die "published SBOM bytes differ"
  cmp -s "$WORK_PROVENANCE_PATH" "$PUBLISH_PROVENANCE_PATH" || die "published provenance bytes differ"
  mv -f "$PUBLISH_SBOM_PATH" "$FINAL_SBOM_PATH"
  mv -f "$PUBLISH_PROVENANCE_PATH" "$FINAL_PROVENANCE_PATH"
  if [[ "$MODE" == "release" ]]; then
    ditto "$WORK_SPARKLE_SIGNATURE_PATH" "$PUBLISH_SPARKLE_SIGNATURE_PATH"
    cmp -s "$WORK_SPARKLE_SIGNATURE_PATH" "$PUBLISH_SPARKLE_SIGNATURE_PATH" || die "published Sparkle signature bytes differ"
    mv -f "$PUBLISH_SPARKLE_SIGNATURE_PATH" "$FINAL_SPARKLE_SIGNATURE_PATH"
  fi
fi
mv -f "$PUBLISH_CHECKSUM_PATH" "$FINAL_CHECKSUM_PATH"
mv -f "$PUBLISH_DMG_PATH" "$FINAL_DMG_PATH"

log "Removing staged app bundle to prevent stale launch collisions"
rm -rf "$STAGED_APP_PATH"

echo "==> Done"
echo "Mode: $MODE"
echo "Build channel: $BUILD_CHANNEL"
echo "DMG path: $FINAL_DMG_PATH"
echo "Checksum: $FINAL_CHECKSUM_PATH"
if [[ "$MODE" == "release-unsigned" ]]; then
  echo "Trust status: public unsigned release; DMG is unsigned and unnotarized; contained app is ad-hoc signed"
  echo "SPDX SBOM: $FINAL_SBOM_PATH"
  echo "Build provenance: $FINAL_PROVENANCE_PATH"
elif ! is_signed_mode; then
  echo "Trust status: local-only; DMG is unsigned and unnotarized; contained app is ad-hoc signed"
else
  echo "Trust status: Developer ID signed, notarized, and stapled"
  if [[ "$MODE" == "release" ]]; then
    echo "SPDX SBOM: $FINAL_SBOM_PATH"
    echo "Build provenance: $FINAL_PROVENANCE_PATH"
    echo "Sparkle EdDSA signature: $FINAL_SPARKLE_SIGNATURE_PATH"
  fi
  echo "Notarization receipts: $AUDIT_ROOT"
fi
