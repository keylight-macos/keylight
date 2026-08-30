#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

APPCAST_URL="${KEYLIGHT_APPCAST_URL:-}"
PUBLIC_KEY="${KEYLIGHT_SPARKLE_PUBLIC_ED_KEY:-}"
EXPECTED_TEAM_ID="${KEYLIGHT_EXPECTED_TEAM_ID:-}"
XCODE_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIGNATURE_VERIFIER="$SCRIPT_DIR/verify-sparkle-signature.swift"
AUDIT_ROOT="$(mktemp -d /tmp/keylight-feed-audit.XXXXXX)"
MOUNT_POINT="$AUDIT_ROOT/mount"
ATTACHED_DEVICE=""

cleanup() {
  local exit_code=$?
  trap - EXIT
  if [[ -n "$ATTACHED_DEVICE" ]]; then
    hdiutil detach "$ATTACHED_DEVICE" >/dev/null 2>&1 || true
  fi
  rm -rf "$AUDIT_ROOT"
  exit "$exit_code"
}
trap cleanup EXIT

[[ "$APPCAST_URL" == https://* ]] || die "KEYLIGHT_APPCAST_URL must use HTTPS"
[[ -n "$PUBLIC_KEY" ]] || die "KEYLIGHT_SPARKLE_PUBLIC_ED_KEY is required"
[[ "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || \
  die "KEYLIGHT_EXPECTED_TEAM_ID must be a ten-character Apple Team ID"
[[ -f "$SIGNATURE_VERIFIER" ]] || die "signature verifier is missing"

APPCAST_PATH="$AUDIT_ROOT/appcast.xml"
curl \
  --fail \
  --silent \
  --show-error \
  --location \
  --proto '=https' \
  --proto-redir '=https' \
  --tlsv1.2 \
  "$APPCAST_URL" \
  --output "$APPCAST_PATH"
xmllint --noout "$APPCAST_PATH"

MODULE_CACHE="$AUDIT_ROOT/module-cache"
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFT_MODULECACHE_PATH="$MODULE_CACHE" \
DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
  xcrun swift "$SIGNATURE_VERIFIER" \
    appcast \
    "$APPCAST_PATH" \
    "$PUBLIC_KEY"

xpath_string() {
  xmllint --xpath "string($1)" "$APPCAST_PATH"
}

ENCLOSURE='(//*[local-name()="item"]/*[local-name()="enclosure"])[1]'
UPDATE_URL="$(xpath_string "$ENCLOSURE/@url")"
UPDATE_SIGNATURE="$(xpath_string "$ENCLOSURE/@*[local-name()='edSignature']")"
UPDATE_LENGTH="$(xpath_string "$ENCLOSURE/@length")"
UPDATE_BUILD="$(xpath_string '(//*[local-name()="item"])[1]/*[local-name()="version"][1]')"
UPDATE_VERSION="$(xpath_string '(//*[local-name()="item"])[1]/*[local-name()="shortVersionString"][1]')"

[[ "$UPDATE_URL" == https://* ]] || die "latest update URL is not HTTPS"
[[ -n "$UPDATE_SIGNATURE" ]] || die "latest update has no EdDSA signature"
[[ "$UPDATE_LENGTH" =~ ^[1-9][0-9]*$ ]] || die "latest update length is invalid"
[[ "$UPDATE_BUILD" =~ ^[1-9][0-9]*$ ]] || die "latest update build is invalid"

UPDATE_PATH="$AUDIT_ROOT/update.dmg"
curl \
  --fail \
  --silent \
  --show-error \
  --location \
  --proto '=https' \
  --proto-redir '=https' \
  --tlsv1.2 \
  "$UPDATE_URL" \
  --output "$UPDATE_PATH"
[[ "$(stat -f '%z' "$UPDATE_PATH")" == "$UPDATE_LENGTH" ]] || \
  die "downloaded update length does not match the signed appcast"
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFT_MODULECACHE_PATH="$MODULE_CACHE" \
DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
  xcrun swift "$SIGNATURE_VERIFIER" \
    archive \
    "$UPDATE_PATH" \
    "$PUBLIC_KEY" \
    "$UPDATE_SIGNATURE" \
    "$UPDATE_LENGTH"

RELEASE_NOTES='(//*[local-name()="item"])[1]/*[local-name()="releaseNotesLink"][1]'
RELEASE_NOTES_URL="$(xpath_string "$RELEASE_NOTES")"
if [[ -n "$RELEASE_NOTES_URL" ]]; then
  RELEASE_NOTES_SIGNATURE="$(xpath_string "$RELEASE_NOTES/@*[local-name()='edSignature']")"
  RELEASE_NOTES_LENGTH="$(xpath_string "$RELEASE_NOTES/@*[local-name()='length']")"
  [[ "$RELEASE_NOTES_URL" == https://* ]] || die "release-notes URL is not HTTPS"
  [[ -n "$RELEASE_NOTES_SIGNATURE" ]] || die "external release notes are unsigned"
  [[ "$RELEASE_NOTES_LENGTH" =~ ^[1-9][0-9]*$ ]] || die "release-notes length is invalid"
  RELEASE_NOTES_PATH="$AUDIT_ROOT/release-notes"
  curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --proto-redir '=https' \
    --tlsv1.2 \
    "$RELEASE_NOTES_URL" \
    --output "$RELEASE_NOTES_PATH"
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  SWIFT_MODULECACHE_PATH="$MODULE_CACHE" \
  DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
    xcrun swift "$SIGNATURE_VERIFIER" \
      archive \
      "$RELEASE_NOTES_PATH" \
      "$PUBLIC_KEY" \
      "$RELEASE_NOTES_SIGNATURE" \
      "$RELEASE_NOTES_LENGTH"
fi

mkdir "$MOUNT_POINT"
hdiutil attach \
  -nobrowse \
  -readonly \
  -mountpoint "$MOUNT_POINT" \
  "$UPDATE_PATH" > "$AUDIT_ROOT/hdiutil.txt"
ATTACHED_DEVICE="$(awk '/^\/dev\// {print $1; exit}' "$AUDIT_ROOT/hdiutil.txt")"
[[ -n "$ATTACHED_DEVICE" ]] || die "could not determine mounted update device"
APP_PATH="$(find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -type d -name 'KeyLight.app' -print -quit)"
[[ -d "$APP_PATH" ]] || die "update does not contain KeyLight.app"
INFO_PATH="$APP_PATH/Contents/Info.plist"
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PATH")" == "com.keylight.app" ]] || \
  die "update has the wrong production bundle identifier"
[[ "$(plutil -extract CFBundleVersion raw -o - "$INFO_PATH")" == "$UPDATE_BUILD" ]] || \
  die "app build does not match signed appcast build"
if [[ -n "$UPDATE_VERSION" ]]; then
  [[ "$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PATH")" == "$UPDATE_VERSION" ]] || \
    die "app version does not match signed appcast version"
fi

CODESIGN_REPORT="$AUDIT_ROOT/codesign.txt"
codesign -dv --verbose=4 "$APP_PATH" >/dev/null 2> "$CODESIGN_REPORT"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" >> "$CODESIGN_REPORT" 2>&1
rg -F "TeamIdentifier=$EXPECTED_TEAM_ID" "$CODESIGN_REPORT" >/dev/null || \
  die "update has the wrong Developer ID TeamIdentifier"
rg -F 'Authority=Developer ID Application:' "$CODESIGN_REPORT" >/dev/null || \
  die "update is not signed by Developer ID Application"
rg '^Timestamp=' "$CODESIGN_REPORT" >/dev/null || die "update lacks a secure timestamp"
DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

hdiutil detach "$ATTACHED_DEVICE" >/dev/null
ATTACHED_DEVICE=""

echo "Signed update feed audit passed."
echo "Version: ${UPDATE_VERSION:-unknown}"
echo "Build: $UPDATE_BUILD"
echo "Bundle ID: com.keylight.app"
echo "Team ID: $EXPECTED_TEAM_ID"
