#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

if [[ "$#" -lt 2 || "$#" -gt 3 ]]; then
  echo "usage: $0 ARCHIVES_DIR HTTPS_DOWNLOAD_URL_PREFIX [APPCAST_FILENAME]" >&2
  exit 2
fi

ARCHIVES_DIR="$1"
DOWNLOAD_URL_PREFIX="$2"
APPCAST_FILENAME="${3:-appcast.xml}"
SPARKLE_TOOLS_DIR="${KEYLIGHT_SPARKLE_TOOLS_DIR:-}"
SPARKLE_PUBLIC_ED_KEY="${KEYLIGHT_SPARKLE_PUBLIC_ED_KEY:-}"
SPARKLE_KEY_ACCOUNT="${KEYLIGHT_SPARKLE_KEY_ACCOUNT:-ed25519}"
EXPECTED_SIGN_UPDATE_SHA256="bfb52400c3da18bb4c251ac4818c2c2e1e31c2e649a45b31c11109b6e57b34ad"
EXPECTED_GENERATE_APPCAST_SHA256="669a5ed0f90ce06fb1de3e36aba35c5da8b98f66928a185fd4029174071be700"
EXPECTED_GENERATE_KEYS_SHA256="2d18ed3a9c744e58150513d9b2e3c2eb76fd0b9621e3e4678d46dd972547e8fe"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLIC_SIGNATURE_VERIFIER="$SCRIPT_DIR/verify-sparkle-signature.swift"
XCODE_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

[[ -d "$ARCHIVES_DIR" ]] || die "archive directory does not exist: $ARCHIVES_DIR"
ARCHIVES_DIR="$(cd "$ARCHIVES_DIR" && pwd -P)"
[[ "$ARCHIVES_DIR" != "/" ]] || die "refusing to use the filesystem root"
if [[ -n "${HOME:-}" ]]; then
  [[ "$ARCHIVES_DIR" != "$HOME" ]] || die "refusing to use the home directory"
fi
[[ "$DOWNLOAD_URL_PREFIX" == https://* ]] || die "download prefix must use HTTPS"
[[ "$DOWNLOAD_URL_PREFIX" == */ ]] || die "download prefix must end with a slash"
[[ "$APPCAST_FILENAME" == "$(basename "$APPCAST_FILENAME")" && "$APPCAST_FILENAME" == *.xml ]] || \
  die "appcast filename must be a plain .xml filename"
[[ -d "$SPARKLE_TOOLS_DIR" ]] || die "KEYLIGHT_SPARKLE_TOOLS_DIR is required"
[[ -n "$SPARKLE_PUBLIC_ED_KEY" ]] || die "KEYLIGHT_SPARKLE_PUBLIC_ED_KEY is required"
[[ -f "$PUBLIC_SIGNATURE_VERIFIER" ]] || die "public Sparkle signature verifier is missing"
[[ -d "$XCODE_DEVELOPER_DIR" ]] || die "Xcode developer directory is missing"

verify_tool() {
  local name="$1"
  local expected_hash="$2"
  local path="$SPARKLE_TOOLS_DIR/$name"
  local actual_hash=""
  [[ -x "$path" ]] || die "missing executable Sparkle tool: $path"
  actual_hash="$(shasum -a 256 "$path" | awk '{print $1}')"
  [[ "$actual_hash" == "$expected_hash" ]] || die "$name is not the reviewed Sparkle 2.9.5 tool"
}

verify_tool sign_update "$EXPECTED_SIGN_UPDATE_SHA256"
verify_tool generate_appcast "$EXPECTED_GENERATE_APPCAST_SHA256"
verify_tool generate_keys "$EXPECTED_GENERATE_KEYS_SHA256"

[[ "$("$SPARKLE_TOOLS_DIR/generate_keys" --account "$SPARKLE_KEY_ACCOUNT" -p)" == "$SPARKLE_PUBLIC_ED_KEY" ]] || \
  die "the Keychain signing key does not match KEYLIGHT_SPARKLE_PUBLIC_ED_KEY"

archive_count="$(find "$ARCHIVES_DIR" -maxdepth 1 -type f -name 'KeyLight-*.dmg' | wc -l | tr -d ' ')"
[[ "$archive_count" -gt 0 ]] || die "no KeyLight DMG archives were found"

"$SPARKLE_TOOLS_DIR/generate_appcast" \
  --account "$SPARKLE_KEY_ACCOUNT" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  -o "$APPCAST_FILENAME" \
  "$ARCHIVES_DIR"

APPCAST_PATH="$ARCHIVES_DIR/$APPCAST_FILENAME"
[[ -s "$APPCAST_PATH" ]] || die "generate_appcast did not create $APPCAST_PATH"
xmllint --noout "$APPCAST_PATH"
"$SPARKLE_TOOLS_DIR/sign_update" \
  --account "$SPARKLE_KEY_ACCOUNT" \
  --verify \
  "$APPCAST_PATH"
MODULE_CACHE_PATH="$(mktemp -d /tmp/keylight-appcast-verifier.XXXXXX)"
trap 'rm -rf "$MODULE_CACHE_PATH"' EXIT
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_PATH" \
SWIFT_MODULECACHE_PATH="$MODULE_CACHE_PATH" \
DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" \
  xcrun swift "$PUBLIC_SIGNATURE_VERIFIER" \
    appcast \
    "$APPCAST_PATH" \
    "$SPARKLE_PUBLIC_ED_KEY"

if rg -U 'enclosure[^>]+url="http://' "$APPCAST_PATH" >/dev/null; then
  die "signed appcast contains an insecure update URL"
fi
if rg -U 'releaseNotesLink[^>]*>[^<]*http://' "$APPCAST_PATH" >/dev/null; then
  die "signed appcast contains an insecure release-notes URL"
fi

echo "Signed appcast: $APPCAST_PATH"
echo "Archives inspected: $archive_count"
echo "Private key source: macOS Keychain account $SPARKLE_KEY_ACCOUNT"
