#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/validate-motion-preview.sh --local VERSION
  ./scripts/validate-motion-preview.sh --signed VERSION

Runs the automated Motion Preview quality gates, builds the isolated preview
DMG, verifies its checksum, confirms the protected original app was unchanged,
and prepares a privacy-safe real-hardware validation report with pending gates.

--local   Produces the ad-hoc local-only Motion Preview candidate.
--signed  Produces the Developer ID/notarized Motion Preview candidate. The
          signed packager runs the complete tests and analyzer internally.

Optional environment:
  KEYLIGHT_PROTECTED_APP_PATH
      App bundle whose file-content fingerprint must remain unchanged.
      Defaults to /Applications/KeyLight.app when it exists.
  KEYLIGHT_CLONED_SOURCE_PACKAGES_DIR
      Verified local Xcode SourcePackages cache forwarded to all builds.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || die "$command_name is required"
}

bundle_fingerprint() {
  local bundle_path="$1"
  {
    find -s "$bundle_path" -type f -print | while IFS= read -r file_path; do
      printf 'file %s %s\n' "$(shasum -a 256 "$file_path" | awk '{print $1}')" "${file_path#"$bundle_path"/}"
    done
    find -s "$bundle_path" -type l -print | while IFS= read -r link_path; do
      printf 'link %s %s\n' "$(readlink "$link_path")" "${link_path#"$bundle_path"/}"
    done
  } | shasum -a 256 | awk '{print $1}'
}

[[ "$#" == 2 ]] || {
  usage >&2
  exit 2
}

case "$1" in
  --local)
    validation_mode="local"
    package_mode="--preview-local"
    dmg_suffix="motion-preview-local-unsigned"
    ;;
  --signed)
    validation_mode="signed"
    package_mode="--preview-signed"
    dmg_suffix="motion-preview-signed"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

version="$2"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || \
  die "VERSION must contain two or three numeric components"

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_path="$root_dir/KeyLight.xcodeproj"
dist_dir="$root_dir/dist"
dmg_path="$dist_dir/KeyLight-$version-$dmg_suffix.dmg"
checksum_path="$dmg_path.sha256"
report_path="$dist_dir/validation/KeyLight-$version-$dmg_suffix-hardware-validation.plist"
protected_app_path="${KEYLIGHT_PROTECTED_APP_PATH:-}"
xcode_developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
validation_root="$(mktemp -d /tmp/KeyLightMotionPreviewValidation.XXXXXX)"
protected_before=""
protected_after=""
source_packages_dir="${KEYLIGHT_CLONED_SOURCE_PACKAGES_DIR:-}"
xcode_package_arguments=(
  -disableAutomaticPackageResolution
  -onlyUsePackageVersionsFromResolvedFile
)

cleanup() {
  local exit_code=$?
  trap - EXIT
  rm -rf "$validation_root"
  exit "$exit_code"
}
trap cleanup EXIT

if [[ -n "$source_packages_dir" ]]; then
  xcode_package_arguments+=(
    -clonedSourcePackagesDirPath "$source_packages_dir"
  )
fi

for command_name in awk bash find git jq plutil readlink shasum xcodebuild; do
  require_command "$command_name"
done
[[ -d "$xcode_developer_dir" ]] || die "Xcode developer directory not found at $xcode_developer_dir"
[[ -x "$root_dir/scripts/build-dmg.sh" ]] || die "build-dmg.sh is missing or not executable"
[[ -x "$root_dir/scripts/hardware-validation.sh" ]] || die "hardware-validation.sh is missing or not executable"

if [[ -z "$protected_app_path" && -d "/Applications/KeyLight.app" ]]; then
  protected_app_path="/Applications/KeyLight.app"
fi
if [[ -n "$protected_app_path" ]]; then
  [[ -d "$protected_app_path" ]] || die "protected app not found: $protected_app_path"
  protected_before="$(bundle_fingerprint "$protected_app_path")"
  echo "Protected original fingerprint before: $protected_before"
fi

echo "==> Checking shell, project, and bundled-preset policy"
for shell_script in "$root_dir"/scripts/*.sh; do
  bash -n "$shell_script"
done
"$root_dir/scripts/verify-project-policy.sh"
jq empty "$root_dir"/KeyLight/Resources/VariantPresets/*.json
while IFS= read -r resource_path; do
  [[ -f "$root_dir/KeyLight/Resources/VariantPresets/$resource_path" ]] || \
    die "bundled layout manifest references missing resource '$resource_path'"
done < <(jq -r '.presets[].resourcePath' "$root_dir/KeyLight/Resources/VariantPresets/variant-presets-manifest.json")

if [[ "$validation_mode" == "local" ]]; then
  echo "==> Running complete Motion Preview test suite"
  DEVELOPER_DIR="$xcode_developer_dir" xcodebuild \
    -quiet \
    "${xcode_package_arguments[@]}" \
    -project "$project_path" \
    -scheme KeyLight \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$validation_root/tests" \
    SWIFT_VERSION=6 \
    SWIFT_STRICT_CONCURRENCY=complete \
    CODE_SIGNING_ALLOWED=NO \
    test

  echo "==> Running Motion Preview static analysis"
  DEVELOPER_DIR="$xcode_developer_dir" xcodebuild \
    -quiet \
    "${xcode_package_arguments[@]}" \
    -project "$project_path" \
    -scheme KeyLight \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$validation_root/analyze" \
    SWIFT_VERSION=6 \
    SWIFT_STRICT_CONCURRENCY=complete \
    CODE_SIGNING_ALLOWED=NO \
    analyze
fi

echo "==> Building verified Motion Preview candidate"
"$root_dir/scripts/build-dmg.sh" "$package_mode" "$version"
[[ -f "$dmg_path" && -f "$checksum_path" ]] || die "packager did not publish the expected candidate and checksum"
(
  cd "$dist_dir"
  shasum -a 256 -c "$(basename "$checksum_path")"
)

if [[ -n "$protected_app_path" ]]; then
  protected_after="$(bundle_fingerprint "$protected_app_path")"
  [[ "$protected_before" == "$protected_after" ]] || \
    die "protected original app changed during Motion Preview validation"
  echo "Protected original fingerprint after:  $protected_after (unchanged)"
fi

"$root_dir/scripts/hardware-validation.sh" prepare "$dmg_path" "$report_path"

echo "==> Automated Motion Preview gates passed"
echo "Candidate: $dmg_path"
echo "Checksum: $checksum_path"
echo "Hardware report: $report_path"
echo "Real-hardware gates remain pending until recorded and verified."
