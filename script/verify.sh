#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CtrlSay"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/CtrlSay.xcodeproj"
DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/$APP_NAME-verify.XXXXXX")"

cleanup() {
  rm -rf -- "$DERIVED_DATA"
}
trap cleanup EXIT

echo "Checking Swift formatting"
xcrun swift-format lint \
  --strict \
  --recursive \
  "$ROOT_DIR/CtrlSay" \
  "$ROOT_DIR/CtrlSayTests" \
  "$ROOT_DIR/Design/AppIcon/generate_layers.swift"

echo "Running Debug tests"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  test \
  -quiet

echo "Running Xcode static analysis"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  analyze \
  -quiet

RELEASE_ARGS=(
  -project "$PROJECT"
  -scheme "$APP_NAME"
  -configuration Release
  -destination 'generic/platform=macOS'
  -derivedDataPath "$DERIVED_DATA"
  ARCHS='arm64 x86_64'
  ONLY_ACTIVE_ARCH=NO
)

echo "Building a signed universal Release app"
xcodebuild "${RELEASE_ARGS[@]}" build -quiet

BUILD_SETTINGS="$(xcodebuild "${RELEASE_ARGS[@]}" -showBuildSettings)"
TARGET_BUILD_DIR="$(awk -F ' = ' '/^[[:space:]]*TARGET_BUILD_DIR = / { print $2; exit }' <<<"$BUILD_SETTINGS")"
APP_BUNDLE="$TARGET_BUILD_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

test -x "$APP_BINARY"
test -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

ARCHITECTURES="$(/usr/bin/lipo -archs "$APP_BINARY")"
for expected_architecture in arm64 x86_64; do
  if [[ " $ARCHITECTURES " != *" $expected_architecture "* ]]; then
    echo "Release binary is missing $expected_architecture: $ARCHITECTURES" >&2
    exit 1
  fi
done

UNEXPECTED_DEPENDENCIES="$(
  /usr/bin/otool -L "$APP_BINARY" \
    | awk '$2 == "(compatibility" { print $1 }' \
    | grep -Ev '^(/System/Library/|/usr/lib/)' \
    || true
)"
if [[ -n "$UNEXPECTED_DEPENDENCIES" ]]; then
  echo "Release app contains non-system dynamic-library dependencies:" >&2
  echo "$UNEXPECTED_DEPENDENCIES" >&2
  exit 1
fi

if LC_ALL=C grep -R -a -l -F "$ROOT_DIR" "$APP_BUNDLE" >/dev/null; then
  echo "Release bundle contains a local source path." >&2
  exit 1
fi

if /usr/bin/strings "$APP_BINARY" \
  | grep -Eq -- '-CtrlSaySeedHUDForTesting|Developer diagnostics|Presentation stress payload'; then
  echo "Release binary contains Debug-only presentation fixtures." >&2
  exit 1
fi

echo "Verification passed ($ARCHITECTURES)"
