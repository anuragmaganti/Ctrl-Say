#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CtrlSay"
BUNDLE_ID="com.anuragmaganti.CtrlSay"
INSTALL_PATH="/Applications/$APP_NAME.app"
INSTALL_STAGING_ROOT=""

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/CtrlSay.xcodeproj"
CONFIGURATION="Debug"
DESTINATION="platform=macOS"
DERIVED_DATA_ARGS=()

if [[ "$MODE" == "--install" || "$MODE" == "install" ]]; then
  CONFIGURATION="Release"
  DESTINATION="generic/platform=macOS"
  DERIVED_DATA_ARGS=(-derivedDataPath "$ROOT_DIR/.build/local-install")
fi

BUILD_ARGS=(
  -project "$PROJECT"
  -scheme "$APP_NAME"
  -configuration "$CONFIGURATION"
  -destination "$DESTINATION"
  "${DERIVED_DATA_ARGS[@]}"
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

verify_signed_app() {
  local app_path="$1"
  local actual_bundle_id
  local signing_details

  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
  actual_bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_path/Contents/Info.plist")"
  signing_details="$(/usr/bin/codesign -dvvv "$app_path" 2>&1)"

  if [[ "$actual_bundle_id" != "$BUNDLE_ID" ]]; then
    echo "Expected bundle identifier $BUNDLE_ID, found $actual_bundle_id." >&2
    return 1
  fi

  if ! grep -q '^Authority=Apple Development:' <<<"$signing_details"; then
    echo "$APP_NAME must have an Apple Development signature before installation." >&2
    return 1
  fi
}

cleanup_install_staging() {
  if [[ -n "$INSTALL_STAGING_ROOT" && -d "$INSTALL_STAGING_ROOT" ]]; then
    rm -rf -- "$INSTALL_STAGING_ROOT"
  fi
}

install_app() {
  local staged_app
  local previous_app

  verify_signed_app "$APP_BUNDLE"
  INSTALL_STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/$APP_NAME-install.XXXXXX")"
  staged_app="$INSTALL_STAGING_ROOT/$APP_NAME.app"
  previous_app="$INSTALL_STAGING_ROOT/previous-$APP_NAME.app"
  trap cleanup_install_staging EXIT

  /usr/bin/ditto "$APP_BUNDLE" "$staged_app"
  verify_signed_app "$staged_app"

  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  for _ in {1..40}; do
    if ! pgrep -x "$APP_NAME" >/dev/null; then
      break
    fi
    sleep 0.05
  done
  if pgrep -x "$APP_NAME" >/dev/null; then
    echo "$APP_NAME did not stop; the installed app was not replaced." >&2
    return 1
  fi

  if [[ -e "$INSTALL_PATH" ]]; then
    /bin/mv "$INSTALL_PATH" "$previous_app"
  fi

  if ! /usr/bin/ditto "$staged_app" "$INSTALL_PATH"; then
    if [[ -e "$previous_app" && ! -e "$INSTALL_PATH" ]]; then
      /bin/mv "$previous_app" "$INSTALL_PATH"
    fi
    echo "Could not install $APP_NAME in /Applications." >&2
    return 1
  fi

  if ! verify_signed_app "$INSTALL_PATH"; then
    rm -rf -- "$INSTALL_PATH"
    if [[ -e "$previous_app" ]]; then
      /bin/mv "$previous_app" "$INSTALL_PATH"
    fi
    echo "The installed bundle failed validation; the previous app was restored." >&2
    return 1
  fi
  /usr/bin/open -n "$INSTALL_PATH"

  for _ in {1..40}; do
    if pgrep -x "$APP_NAME" >/dev/null; then
      echo "Installed and launched $INSTALL_PATH"
      return 0
    fi
    sleep 0.1
  done

  rm -rf -- "$INSTALL_PATH"
  if [[ -e "$previous_app" ]]; then
    /bin/mv "$previous_app" "$INSTALL_PATH"
  fi
  echo "$APP_NAME did not launch; the previous app was restored." >&2
  return 1
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
  --stress-hud|stress-hud)
    /usr/bin/open -n "$APP_BUNDLE" --args -CtrlSayStressHUDLayoutForTesting
    ;;
  --stress-surfaces|stress-surfaces)
    /usr/bin/open -n "$APP_BUNDLE" --args -CtrlSayStressPresentationSurfacesForTesting
    ;;
  --install|install)
    install_app
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--stress-hud|--stress-surfaces|--install]" >&2
    exit 2
    ;;
esac
