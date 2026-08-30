#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="KeyLight"
BUNDLE_ID="com.keylight.app.debug"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/KeyLight.xcodeproj"
BUILD_ROOT="${KEYLIGHT_LOCAL_BUILD_ROOT:-/tmp/KeyLightLocalBuild}"
DERIVED_DATA_PATH="$BUILD_ROOT/DerivedData"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
XCODE_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  SWIFT_VERSION=6 \
  SWIFT_STRICT_CONCURRENCY=complete \
  build

if [[ ! -d "$APP_BUNDLE" || ! -x "$APP_BINARY" ]]; then
  echo "error: built app not found at $APP_BUNDLE" >&2
  exit 1
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    /usr/bin/lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\" OR process == \"$APP_NAME\""
    ;;
  --verify|verify)
    open_app
    launched=false
    for _ in {1..25}; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        launched=true
        break
      fi
      sleep 0.2
    done
    if [[ "$launched" != true ]]; then
      echo "error: $APP_NAME did not launch" >&2
      exit 1
    fi
    sleep 1
    if ! pgrep -x "$APP_NAME" >/dev/null; then
      echo "error: $APP_NAME did not remain running after launch" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
