#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CtrlSay"
BUNDLE_ID="com.anuragmaganti.CtrlSay"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/CtrlSay.xcodeproj"
BUILD_ARGS=(
  -project "$PROJECT"
  -scheme "$APP_NAME"
  -configuration Debug
  -destination "platform=macOS"
)

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
for _ in {1..40}; do
  if ! pgrep -x "$APP_NAME" >/dev/null; then
    break
  fi
  sleep 0.05
done

if pgrep -x "$APP_NAME" >/dev/null; then
  echo "$APP_NAME did not stop; stop the active Xcode run and try again." >&2
  exit 1
fi

xcodebuild "${BUILD_ARGS[@]}" build

BUILD_SETTINGS="$(xcodebuild "${BUILD_ARGS[@]}" -showBuildSettings)"
TARGET_BUILD_DIR="$(awk -F ' = ' '/^[[:space:]]*TARGET_BUILD_DIR = / { print $2; exit }' <<<"$BUILD_SETTINGS")"
APP_BUNDLE="$TARGET_BUILD_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
