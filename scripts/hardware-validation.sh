#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/hardware-validation.sh prepare DMG [REPORT]
  ./scripts/hardware-validation.sh record REPORT GATE STATUS [NOTES]
  ./scripts/hardware-validation.sh list REPORT
  ./scripts/hardware-validation.sh verify REPORT DMG
  ./scripts/hardware-validation.sh verify-suite DMG REPORT [REPORT ...]

Statuses: pending, pass, fail, blocked, not-applicable

`prepare` records only non-identifying machine/build metadata. It never records
serial numbers, hardware UUIDs, display UUIDs, key codes, or typed content.
Use `record` after each real-hardware check. `verify-suite` requires every gate
to pass in at least one report, which allows macOS 14 and macOS 26 coverage to
come from separate machines without treating "not-applicable" as coverage.
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

timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

GATE_IDS=(
  ansi_chords
  iso_chords
  modifier_chords
  chord_appearance
  guided_calibration
  media_fn_caps_lock
  display_routing_builtin
  display_routing_external_clamshell
  multi_display_mirroring
  spaces_full_screen
  appearance_routes
  automatic_power_saving
  snapshot_recovery
  accessibility_modes
  customizable_shortcut
  macos14_classic
  macos26_surfaces
  latency_p99
  idle_cpu
  typing_stress
)

GATE_TITLES=(
  "ANSI keyboard: two-, three-, and four-key chords remain lit through staggered release"
  "ISO keyboard: two-, three-, and four-key chords remain lit through staggered release"
  "Modifier chords: Command, Option, Control, Shift, and mixed chords retain every held surface"
  "Natural Merge and Independent chords render correctly at 50, 100, and 150 percent through arbitrary release order"
  "Guided calibration completes all nine anchors, review, cancel/close safety, unique naming, and new-profile activation"
  "Media, Fn, and Caps Lock actions render without stuck surfaces"
  "Built-in display routing follows the selected display and bound layout profile"
  "External display and clamshell routing follow the selected display and fallback policy"
  "One primary plus at least one mirrored physical display survives resize, disconnect/reconnect, sleep, and wake without stale keys"
  "Spaces and full-screen transitions keep the overlay positioned and click-through"
  "Light, Dark, textured backgrounds, and supported appearance routes remain visually correct"
  "Automatic power saving stops Physical Refraction capture, preserves held keys and the selected setting, then restores once"
  "Configuration snapshot apply, failed-apply rollback, and Restore Previous Setup preserve the complete managed setup"
  "VoiceOver, Reduce Motion, Reduce Transparency, and Increase Contrast behave correctly"
  "A recorded global shortcut re-registers, persists, toggles once, and can be reset"
  "macOS 14 runs Classic Glow with no unavailable-symbol launch failure"
  "macOS 26 runs Classic Glow, System Glass, Physical Refraction, and Solid Black"
  "Signed Release input-to-render submission p99 is below 16.7 ms"
  "Signed Release idle median CPU is below 0.5 percent over five minutes"
  "Sixty-second typing stress has no event-tap timeout, stuck glow, or unbounded renderer growth"
)

gate_index() {
  local requested="$1"
  local index=0
  for ((index = 0; index < ${#GATE_IDS[@]}; index++)); do
    if [[ "${GATE_IDS[$index]}" == "$requested" ]]; then
      printf '%s\n' "$index"
      return 0
    fi
  done
  return 1
}

plist_value() {
  local report_path="$1"
  local key_path="$2"
  plutil -extract "$key_path" raw -o - "$report_path" 2>/dev/null || true
}

validate_report_schema() {
  local report_path="$1"
  [[ -f "$report_path" ]] || die "validation report not found: $report_path"
  plutil -lint "$report_path" >/dev/null || die "validation report is not a valid property list"
  [[ "$(plist_value "$report_path" schemaVersion)" == "1" ]] || \
    die "validation report has an unsupported schema"
  local gate_id=""
  for gate_id in "${GATE_IDS[@]}"; do
    [[ -n "$(plist_value "$report_path" "gates.$gate_id.title")" ]] || \
      die "validation report is missing gate '$gate_id'"
  done
}

artifact_hash() {
  shasum -a 256 "$1" | awk '{print $1}'
}

verify_candidate_hash() {
  local report_path="$1"
  local dmg_path="$2"
  [[ -f "$dmg_path" ]] || die "candidate DMG not found: $dmg_path"
  local expected_hash=""
  local actual_hash=""
  expected_hash="$(plist_value "$report_path" candidate.dmgSHA256)"
  actual_hash="$(artifact_hash "$dmg_path")"
  [[ "$expected_hash" == "$actual_hash" ]] || \
    die "validation report does not describe the supplied DMG"
}

prepare_report() {
  local dmg_path="$1"
  local requested_report_path="${2:-}"
  local temp_root=""
  local mount_point=""
  local attach_report=""
  local attached_device=""
  local app_path=""
  local app_count=""
  local info_path=""
  local executable_name=""
  local binary_path=""
  local app_version=""
  local app_build=""
  local bundle_id=""
  local build_channel=""
  local architectures=""
  local dmg_sha256=""
  local report_path=""
  local work_report=""
  local signature_report=""
  local team_id=""
  local trust="ad-hoc local"
  local stapled=false
  local source_commit="unavailable"
  local gate_id=""
  local gate_title=""
  local index=0

  [[ -f "$dmg_path" ]] || die "candidate DMG not found: $dmg_path"
  for command_name in awk codesign date ditto find hdiutil lipo mktemp mkdir plutil rg shasum sw_vers sysctl wc xcrun; do
    require_command "$command_name"
  done

  temp_root="$(mktemp -d /tmp/KeyLightHardwareValidation.XXXXXX)"
  mount_point="$temp_root/mount"
  attach_report="$temp_root/hdiutil-attach.txt"
  mkdir -p "$mount_point"

  cleanup_prepare() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$attached_device" ]]; then
      hdiutil detach "$attached_device" >/dev/null 2>&1 || true
    fi
    rm -rf "$temp_root"
    exit "$exit_code"
  }
  trap cleanup_prepare EXIT

  hdiutil attach -nobrowse -readonly -mountpoint "$mount_point" "$dmg_path" > "$attach_report"
  attached_device="$(awk '/^\/dev\// {print $1; exit}' "$attach_report")"
  [[ -n "$attached_device" ]] || die "could not determine the mounted DMG device"

  app_count="$(find "$mount_point" -mindepth 1 -maxdepth 1 -type d -name '*.app' | wc -l | tr -d '[:space:]')"
  [[ "$app_count" == "1" ]] || die "candidate DMG must contain exactly one app"
  app_path="$(find "$mount_point" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print -quit)"
  info_path="$app_path/Contents/Info.plist"
  [[ -f "$info_path" ]] || die "candidate app Info.plist is missing"

  executable_name="$(plist_value "$info_path" CFBundleExecutable)"
  app_version="$(plist_value "$info_path" CFBundleShortVersionString)"
  app_build="$(plist_value "$info_path" CFBundleVersion)"
  bundle_id="$(plist_value "$info_path" CFBundleIdentifier)"
  build_channel="$(plist_value "$info_path" KeyLightBuildChannel)"
  binary_path="$app_path/Contents/MacOS/$executable_name"
  [[ -x "$binary_path" ]] || die "candidate app executable is missing"
  architectures="$(lipo -archs "$binary_path")"
  dmg_sha256="$(artifact_hash "$dmg_path")"

  signature_report="$temp_root/codesign.txt"
  codesign -dv --verbose=4 "$app_path" >/dev/null 2> "$signature_report"
  team_id="$(sed -n -E 's/^TeamIdentifier=(.*)$/\1/p' "$signature_report" | tail -n 1)"
  if [[ -n "$team_id" && "$team_id" != "not set" ]]; then
    trust="Developer ID"
  else
    team_id="not set"
  fi
  if xcrun stapler validate "$app_path" >/dev/null 2>&1; then
    stapled=true
  fi

  if git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" rev-parse HEAD >/dev/null 2>&1; then
    source_commit="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" rev-parse HEAD)"
  fi

  if [[ -n "$requested_report_path" ]]; then
    report_path="$requested_report_path"
  else
    report_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dist/validation/KeyLight-$app_version-$app_build-hardware-validation.plist"
  fi
  if [[ -e "$report_path" && "${KEYLIGHT_OVERWRITE:-0}" != "1" ]]; then
    die "refusing to overwrite existing report at $report_path (set KEYLIGHT_OVERWRITE=1 intentionally)"
  fi
  mkdir -p "$(dirname "$report_path")"

  work_report="$temp_root/report.plist"
  plutil -create xml1 "$work_report"
  plutil -insert schemaVersion -integer 1 "$work_report"
  plutil -insert preparedAt -string "$(timestamp)" "$work_report"
  plutil -insert lastUpdatedAt -string "$(timestamp)" "$work_report"
  plutil -insert privacyNotice -string "No serial number, hardware UUID, display UUID, key code, or typed content is recorded. Keep free-form notes equally non-identifying." "$work_report"

  plutil -insert candidate -dictionary "$work_report"
  plutil -insert candidate.dmgName -string "$(basename "$dmg_path")" "$work_report"
  plutil -insert candidate.dmgSHA256 -string "$dmg_sha256" "$work_report"
  plutil -insert candidate.appName -string "$(basename "$app_path")" "$work_report"
  plutil -insert candidate.version -string "$app_version" "$work_report"
  plutil -insert candidate.build -string "$app_build" "$work_report"
  plutil -insert candidate.bundleIdentifier -string "$bundle_id" "$work_report"
  plutil -insert candidate.buildChannel -string "$build_channel" "$work_report"
  plutil -insert candidate.architectures -string "$architectures" "$work_report"
  plutil -insert candidate.trust -string "$trust" "$work_report"
  plutil -insert candidate.teamIdentifier -string "$team_id" "$work_report"
  plutil -insert candidate.notarizationStapled -bool "$stapled" "$work_report"

  plutil -insert environment -dictionary "$work_report"
  plutil -insert environment.hardwareModel -string "$(sysctl -n hw.model)" "$work_report"
  plutil -insert environment.architecture -string "$(uname -m)" "$work_report"
  plutil -insert environment.macOSVersion -string "$(sw_vers -productVersion)" "$work_report"
  plutil -insert environment.macOSBuild -string "$(sw_vers -buildVersion)" "$work_report"
  plutil -insert sourceCommit -string "$source_commit" "$work_report"

  plutil -insert gates -dictionary "$work_report"
  for ((index = 0; index < ${#GATE_IDS[@]}; index++)); do
    gate_id="${GATE_IDS[$index]}"
    gate_title="${GATE_TITLES[$index]}"
    plutil -insert "gates.$gate_id" -dictionary "$work_report"
    plutil -insert "gates.$gate_id.title" -string "$gate_title" "$work_report"
    plutil -insert "gates.$gate_id.status" -string pending "$work_report"
    plutil -insert "gates.$gate_id.notes" -string "" "$work_report"
    plutil -insert "gates.$gate_id.updatedAt" -string "" "$work_report"
  done

  plutil -lint "$work_report" >/dev/null
  ditto "$work_report" "$report_path"
  hdiutil detach "$attached_device" >/dev/null
  attached_device=""
  trap - EXIT
  rm -rf "$temp_root"

  echo "Prepared hardware validation report: $report_path"
  echo "Candidate SHA-256: $dmg_sha256"
  echo "All gates are pending until recorded from real hardware."
}

record_gate() {
  local report_path="$1"
  local gate_id="$2"
  local status="$3"
  local notes="${4:-}"
  local index=""
  local temp_report=""

  validate_report_schema "$report_path"
  index="$(gate_index "$gate_id" || true)"
  [[ -n "$index" ]] || die "unknown gate '$gate_id'"
  case "$status" in
    pending|pass|fail|blocked|not-applicable)
      ;;
    *)
      die "status must be pending, pass, fail, blocked, or not-applicable"
      ;;
  esac
  if [[ "$status" == "not-applicable" || "$status" == "fail" || "$status" == "blocked" ]]; then
    [[ -n "$notes" ]] || die "$status requires a concise note"
  fi
  case "$gate_id" in
    latency_p99|idle_cpu|typing_stress)
      if [[ "$status" == "pass" ]]; then
        [[ -n "$notes" ]] || die "$gate_id pass requires the measured result in notes"
      fi
      ;;
  esac

  temp_report="$(mktemp "${report_path}.tmp.XXXXXX")"
  ditto "$report_path" "$temp_report"
  plutil -replace "gates.$gate_id.status" -string "$status" "$temp_report"
  plutil -replace "gates.$gate_id.notes" -string "$notes" "$temp_report"
  plutil -replace "gates.$gate_id.updatedAt" -string "$(timestamp)" "$temp_report"
  plutil -replace lastUpdatedAt -string "$(timestamp)" "$temp_report"
  plutil -lint "$temp_report" >/dev/null
  mv -f "$temp_report" "$report_path"
  echo "Recorded $gate_id: $status"
}

list_report() {
  local report_path="$1"
  local gate_id=""
  local title=""
  local status=""
  local notes=""
  validate_report_schema "$report_path"
  echo "Candidate: $(plist_value "$report_path" candidate.dmgName)"
  echo "SHA-256:  $(plist_value "$report_path" candidate.dmgSHA256)"
  for gate_id in "${GATE_IDS[@]}"; do
    title="$(plist_value "$report_path" "gates.$gate_id.title")"
    status="$(plist_value "$report_path" "gates.$gate_id.status")"
    notes="$(plist_value "$report_path" "gates.$gate_id.notes")"
    printf '%-36s %-14s %s\n' "$gate_id" "$status" "$title"
    if [[ -n "$notes" ]]; then
      printf '  notes: %s\n' "$notes"
    fi
  done
}

verify_report() {
  local report_path="$1"
  local dmg_path="$2"
  local gate_id=""
  local status=""
  local notes=""
  local incomplete=0

  validate_report_schema "$report_path"
  verify_candidate_hash "$report_path" "$dmg_path"
  for gate_id in "${GATE_IDS[@]}"; do
    status="$(plist_value "$report_path" "gates.$gate_id.status")"
    notes="$(plist_value "$report_path" "gates.$gate_id.notes")"
    case "$status" in
      pass)
        ;;
      not-applicable)
        [[ -n "$notes" ]] || die "$gate_id is not-applicable without a note"
        ;;
      pending|fail|blocked)
        echo "$gate_id: $status" >&2
        incomplete=1
        ;;
      *)
        die "$gate_id has invalid status '$status'"
        ;;
    esac
    case "$gate_id" in
      latency_p99|idle_cpu|typing_stress)
        if [[ "$status" == "pass" && -z "$notes" ]]; then
          die "$gate_id pass is missing its measured result"
        fi
        ;;
    esac
  done
  [[ "$incomplete" == "0" ]] || die "hardware validation report is incomplete or failing"
  echo "Hardware validation report is internally complete for $(basename "$dmg_path")."
}

verify_suite() {
  local dmg_path="$1"
  shift
  [[ "$#" -gt 0 ]] || die "verify-suite requires at least one report"
  local report_path=""
  local gate_id=""
  local status=""
  local covered=0

  for report_path in "$@"; do
    verify_report "$report_path" "$dmg_path" >/dev/null
  done
  for gate_id in "${GATE_IDS[@]}"; do
    covered=0
    for report_path in "$@"; do
      status="$(plist_value "$report_path" "gates.$gate_id.status")"
      if [[ "$status" == "pass" ]]; then
        covered=1
        break
      fi
    done
    [[ "$covered" == "1" ]] || die "validation suite has no passing coverage for '$gate_id'"
  done
  echo "Hardware validation suite passes all ${#GATE_IDS[@]} gates for $(basename "$dmg_path")."
}

[[ "$#" -ge 1 ]] || {
  usage >&2
  exit 2
}

case "$1" in
  prepare)
    [[ "$#" -ge 2 && "$#" -le 3 ]] || { usage >&2; exit 2; }
    prepare_report "$2" "${3:-}"
    ;;
  record)
    [[ "$#" -ge 4 && "$#" -le 5 ]] || { usage >&2; exit 2; }
    record_gate "$2" "$3" "$4" "${5:-}"
    ;;
  list)
    [[ "$#" == 2 ]] || { usage >&2; exit 2; }
    list_report "$2"
    ;;
  verify)
    [[ "$#" == 3 ]] || { usage >&2; exit 2; }
    verify_report "$2" "$3"
    ;;
  verify-suite)
    [[ "$#" -ge 3 ]] || { usage >&2; exit 2; }
    shift
    verify_suite "$@"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
