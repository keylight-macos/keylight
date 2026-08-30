#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/KeyLight.xcodeproj/project.pbxproj"
PACKAGE_RESOLVED="$ROOT_DIR/KeyLight.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
PRIVACY_MANIFEST="$ROOT_DIR/KeyLight/Resources/PrivacyInfo.xcprivacy"
ENTITLEMENTS="$ROOT_DIR/KeyLight/KeyLight.entitlements"
INFO_PLIST="$ROOT_DIR/KeyLight/Info.plist"
SHARED_CONFIG="$ROOT_DIR/Configurations/Shared.xcconfig"
APP_DELEGATE="$ROOT_DIR/KeyLight/AppDelegate.swift"
BUILD_DMG_SCRIPT="$ROOT_DIR/scripts/build-dmg.sh"
RELEASE_METADATA_GENERATOR="$ROOT_DIR/scripts/generate-release-metadata.swift"
HARDWARE_VALIDATION_SCRIPT="$ROOT_DIR/scripts/hardware-validation.sh"
MOTION_PREVIEW_VALIDATOR="$ROOT_DIR/scripts/validate-motion-preview.sh"
VARIANT_PROFILE="$ROOT_DIR/docs/variants/macbook-air-13-m4/keylight-layout-profile-template.json"
PRIVACY_LOGGING_AWK="$ROOT_DIR/scripts/verify-privacy-logging.awk"

die() {
  echo "error: $*" >&2
  exit 1
}

for command_name in awk plutil rg sed tr xargs; do
  command -v "$command_name" >/dev/null 2>&1 || die "$command_name is required"
done

for required_path in \
  "$PROJECT_FILE" \
  "$PACKAGE_RESOLVED" \
  "$PRIVACY_MANIFEST" \
  "$ENTITLEMENTS" \
  "$INFO_PLIST" \
  "$SHARED_CONFIG" \
  "$APP_DELEGATE" \
  "$BUILD_DMG_SCRIPT" \
  "$RELEASE_METADATA_GENERATOR" \
  "$HARDWARE_VALIDATION_SCRIPT" \
  "$MOTION_PREVIEW_VALIDATOR" \
  "$VARIANT_PROFILE" \
  "$PRIVACY_LOGGING_AWK"; do
  [[ -f "$required_path" ]] || die "required policy input is missing: $required_path"
done

[[ "$(rg -c 'Add :com\.apple\.security\.cs\.disable-library-validation bool true' \
  "$BUILD_DMG_SCRIPT")" == "1" ]] || \
  die "local packaging must declare exactly one scoped Sparkle library-validation exception"
rg -F -- '--entitlements "$LOCAL_ADHOC_ENTITLEMENTS_PATH"' \
  "$BUILD_DMG_SCRIPT" >/dev/null || \
  die "local packaging must sign only from its generated ad-hoc entitlement file"
rg -F 'KEYLIGHT_PACKAGE_LAUNCH_SMOKE_TEST' "$APP_DELEGATE" >/dev/null || \
  die "the app entry point must retain side-effect-free package smoke mode"
rg -F 'run_packaged_launch_smoke_test "$STAGED_APP_PATH"' \
  "$BUILD_DMG_SCRIPT" >/dev/null || \
  die "packaging must launch-test the final staged app before DMG creation"
rg -F './scripts/build-dmg.sh --preview-signed VERSION' \
  "$BUILD_DMG_SCRIPT" >/dev/null || \
  die "packaging must retain the signed Motion Preview mode"
rg -F 'BUILD_CHANNEL="Motion Preview Signed"' \
  "$BUILD_DMG_SCRIPT" >/dev/null || \
  die "signed Motion Preview packaging must identify its build channel"
rg -F 'FINAL_DMG_NAME="KeyLight-$VERSION-motion-preview-signed.dmg"' \
  "$BUILD_DMG_SCRIPT" >/dev/null || \
  die "signed Motion Preview packaging must use an unmistakable artifact name"
rg -F 'verify_signed_preview_source_state' \
  "$BUILD_DMG_SCRIPT" >/dev/null || \
  die "signed Motion Preview packaging must require a clean committed candidate"
rg -F 'hardware-validation.sh" prepare' \
  "$MOTION_PREVIEW_VALIDATOR" >/dev/null || \
  die "Motion Preview validation must prepare a candidate-bound hardware report"
rg -F 'Protected original fingerprint before:' \
  "$MOTION_PREVIEW_VALIDATOR" >/dev/null || \
  die "Motion Preview validation must fingerprint the protected original app"
rg -F './scripts/build-dmg.sh --release-unsigned VERSION' \
  "$BUILD_DMG_SCRIPT" >/dev/null || \
  die "packaging must retain the unsigned production-release mode"
rg -F 'BUILD_CHANNEL="Unsigned Release"' \
  "$BUILD_DMG_SCRIPT" >/dev/null || \
  die "unsigned production packaging must identify its trust channel"
rg -F 'verify_unsigned_release_source_state' \
  "$BUILD_DMG_SCRIPT" >/dev/null || \
  die "unsigned production packaging must require a clean committed candidate"
rg -F 'requires_full_quality_gates' \
  "$BUILD_DMG_SCRIPT" >/dev/null || \
  die "unsigned production packaging must run full quality gates"
rg -F 'remove_unsigned_release_update_keys "$STAGED_APP_PATH"' \
  "$BUILD_DMG_SCRIPT" >/dev/null || \
  die "unsigned production packaging must remove inactive update keys before signing"
rg -F 'plutil -remove "$update_key" "$info_path"' \
  "$BUILD_DMG_SCRIPT" >/dev/null || \
  die "unsigned production packaging must delete update keys from its staged app"
rg -F 'releaseMode == "release" || releaseMode == "release-unsigned"' \
  "$RELEASE_METADATA_GENERATOR" >/dev/null || \
  die "release provenance must distinguish signed and unsigned releases"
for forbidden_hardware_identifier in \
  IOPlatformSerialNumber \
  IOPlatformUUID \
  SPHardwareDataType \
  CGDisplayCreateUUIDFromDisplayID; do
  if rg -F "$forbidden_hardware_identifier" \
    "$HARDWARE_VALIDATION_SCRIPT" >/dev/null; then
    die "hardware validation must not query $forbidden_hardware_identifier"
  fi
done

[[ "$(rg -c '"identity"[[:space:]]*:' "$PACKAGE_RESOLVED")" == "1" ]] || \
  die "Package.resolved must contain exactly one dependency"
[[ "$(plutil -extract pins.0.identity raw -o - "$PACKAGE_RESOLVED")" == "sparkle" ]] || \
  die "the only dependency must be Sparkle"
[[ "$(plutil -extract pins.0.state.version raw -o - "$PACKAGE_RESOLVED")" == "2.9.5" ]] || \
  die "Sparkle must be exactly pinned to 2.9.5"
[[ "$(plutil -extract pins.0.state.revision raw -o - "$PACKAGE_RESOLVED")" == \
  "79bc9e872948e47877e76f194cb0c8e0412b0b90" ]] || \
  die "Sparkle revision does not match the reviewed 2.9.5 source"
rg -U 'kind = exactVersion;[[:space:]]+version = 2\.9\.5;' "$PROJECT_FILE" >/dev/null || \
  die "the Xcode project does not require exact Sparkle 2.9.5"

plutil -lint "$PRIVACY_MANIFEST" >/dev/null
[[ "$(plutil -extract NSPrivacyTracking raw -o - "$PRIVACY_MANIFEST")" == "false" ]] || \
  die "privacy manifest must disable tracking"
for expected_privacy_value in \
  NSPrivacyAccessedAPICategoryFileTimestamp \
  3B52.1 \
  NSPrivacyAccessedAPICategorySystemBootTime \
  35F9.1 \
  NSPrivacyAccessedAPICategoryUserDefaults \
  CA92.1; do
  rg -F "$expected_privacy_value" "$PRIVACY_MANIFEST" >/dev/null || \
    die "privacy manifest is missing $expected_privacy_value"
done

[[ "$(plutil -p "$ENTITLEMENTS" | tr -d '[:space:]')" == "{}" ]] || \
  die "KeyLight's main entitlement set must remain empty"
plutil -lint "$INFO_PLIST" >/dev/null
for updater_policy in \
  SUEnableAutomaticChecks:false \
  SUAutomaticallyUpdate:false \
  SUSendProfileInfo:false \
  SUVerifyUpdateBeforeExtraction:true \
  SURequireSignedFeed:true; do
  updater_key="${updater_policy%%:*}"
  expected_value="${updater_policy##*:}"
  [[ "$(plutil -extract "$updater_key" raw -o - "$INFO_PLIST")" == "$expected_value" ]] || \
    die "Info.plist updater policy '$updater_key' must be '$expected_value'"
done
[[ "$(plutil -extract SUSignedFeedFailureExpirationInterval raw -o - "$INFO_PLIST")" == "0" ]] || \
  die "signed feed verification must fail closed"
[[ "$(plutil -extract SUFeedURL raw -o - "$INFO_PLIST")" == '$(KEYLIGHT_SPARKLE_FEED_URL)' ]] || \
  die "Info.plist feed URL must come only from the release build setting"
[[ "$(plutil -extract SUPublicEDKey raw -o - "$INFO_PLIST")" == '$(KEYLIGHT_SPARKLE_PUBLIC_ED_KEY)' ]] || \
  die "Info.plist public key must come only from the release build setting"
[[ "$(plutil -extract KeyLightBuildChannel raw -o - "$INFO_PLIST")" == '$(KEYLIGHT_BUILD_CHANNEL)' ]] || \
  die "Info.plist build channel must come only from the shared build setting"
rg -U '^MARKETING_VERSION = [0-9]+\.[0-9]+\.[0-9]+$' "$SHARED_CONFIG" >/dev/null || \
  die "Shared.xcconfig must contain one semantic MARKETING_VERSION"
rg -U '^CURRENT_PROJECT_VERSION = [1-9][0-9]*$' "$SHARED_CONFIG" >/dev/null || \
  die "Shared.xcconfig must contain one positive CURRENT_PROJECT_VERSION"
rg -F 'must match Shared.xcconfig MARKETING_VERSION' "$BUILD_DMG_SCRIPT" >/dev/null || \
  die "packaging must reject a version that differs from Shared.xcconfig"
rg -F 'must match Shared.xcconfig CURRENT_PROJECT_VERSION' "$BUILD_DMG_SCRIPT" >/dev/null || \
  die "packaging must reject a build number that differs from Shared.xcconfig"
rg -F 'ENABLE_HARDENED_RUNTIME = YES;' "$PROJECT_FILE" >/dev/null || \
  die "Release must enable Hardened Runtime"
rg -F 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;' "$PROJECT_FILE" >/dev/null || \
  die "Release must reject injected base entitlements"

for forbidden_entitlement in \
  com.apple.security.get-task-allow \
  com.apple.security.cs.allow-jit \
  com.apple.security.cs.allow-unsigned-executable-memory \
  com.apple.security.cs.disable-library-validation \
  com.apple.security.network.client \
  com.apple.security.network.server; do
  if rg -F "$forbidden_entitlement" \
    "$ROOT_DIR/KeyLight" \
    "$ROOT_DIR/Configurations" \
    "$PROJECT_FILE" >/dev/null; then
    die "forbidden entitlement declared in source: $forbidden_entitlement"
  fi
done

rg -U 'static let eventTapOptions:[[:space:]]*CGEventTapOptions[[:space:]]*=[[:space:]]*\.listenOnly' \
  "$ROOT_DIR/KeyLight/Services/KeyboardMonitor.swift" >/dev/null || \
  die "the global event-tap contract must remain listen-only"
rg -U 'CGEvent\.tapCreate\([\s\S]{0,800}options:[[:space:]]*Self\.eventTapOptions' \
  "$ROOT_DIR/KeyLight/Services/KeyboardMonitor.swift" >/dev/null || \
  die "the global event tap must use the tested listen-only contract"

[[ "$(plutil -extract 'keyOffsets.10' raw -o - "$VARIANT_PROFILE")" == "0.012000" ]] || \
  die "the bundled MacBook Air profile key 10 offset changed unexpectedly"
[[ "$(plutil -extract 'keyOffsets.44' raw -o - "$VARIANT_PROFILE")" == "-0.008000" ]] || \
  die "the bundled MacBook Air profile key 44 offset changed unexpectedly"
[[ "$(plutil -extract 'keyOffsets.123' raw -o - "$VARIANT_PROFILE")" == "0.006000" ]] || \
  die "the bundled MacBook Air profile key 123 offset changed unexpectedly"
[[ "$(plutil -extract 'keyWidthOverrides.10' raw -o - "$VARIANT_PROFILE")" == "1.120000" ]] || \
  die "the bundled MacBook Air profile key 10 width changed unexpectedly"
[[ "$(plutil -extract 'keyWidthOverrides.49' raw -o - "$VARIANT_PROFILE")" == "1.030000" ]] || \
  die "the bundled MacBook Air profile key 49 width changed unexpectedly"
[[ "$(plutil -extract 'keyWidthOverrides.123' raw -o - "$VARIANT_PROFILE")" == "0.950000" ]] || \
  die "the bundled MacBook Air profile key 123 width changed unexpectedly"

if rg -n \
  --glob '!UpdateService.swift' \
  --glob '!*.xcstrings' \
  '\b(URLSession|NSURLConnection|NWConnection|NWTCPConnection)\b' \
  "$ROOT_DIR/KeyLight" >/dev/null; then
  die "an unreviewed network client exists outside UpdateService/Sparkle"
fi

if ! rg --files "$ROOT_DIR/KeyLight" -g '*.swift' -0 \
  | xargs -0 awk -f "$PRIVACY_LOGGING_AWK"; then
  die "a log or signpost contains privacy-sensitive input or imported-data metadata"
fi

secret_patterns=(
  'AKIA[0-9A-Z]{16}'
  'gh[pousr]_[A-Za-z0-9]{30,}'
  'github_pat_[A-Za-z0-9_]{30,}'
  'xox[baprs]-[A-Za-z0-9-]{20,}'
  'sk_live_[A-Za-z0-9]{20,}'
  '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'
)
for secret_pattern in "${secret_patterns[@]}"; do
  if rg -n \
    --hidden \
    --glob '!.git/**' \
    --glob '!dist/**' \
    --glob '!.build/**' \
    -- "$secret_pattern" \
    "$ROOT_DIR" >/dev/null; then
    die "potential secret matched source policy pattern: $secret_pattern"
  fi
done

echo "Project security, dependency, privacy, and secret policy checks passed."
