#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$REPO_ROOT/apps/dev-station/DevStation.xcodeproj"
SCHEME="DevStation"
DERIVED="${DEVSTATION_DERIVED_PATH:-${TMPDIR:-/tmp}/devstation-derived}"
OUT_DIR="$REPO_ROOT/dist"
BUILD_DIR="$REPO_ROOT/dist/build"
APP_NAME="DevStation.app"
PLIST_NAME="Dev Station"
CONFIGURATION="${DEVSTATION_CONFIGURATION:-Release}"
CLEAN="${DEVSTATION_CLEAN:-1}"

source "$REPO_ROOT/tools/_app_bundle.sh"

if [[ ! -d "$PROJECT" ]]; then
  echo "devstation-build: project not found at $PROJECT" >&2
  exit 2
fi

if [[ "$DERIVED" == "/path/you/want" || "$DERIVED" == *"/path/you/want"* ]]; then
  echo "devstation-build: DEVSTATION_DERIVED_PATH is a placeholder ('$DERIVED'); falling back to a temp path." >&2
  DERIVED="${TMPDIR:-/tmp}/devstation-derived"
fi

if ! mkdir -p "$DERIVED" 2>/dev/null; then
  echo "devstation-build: derivedDataPath '$DERIVED' is not writable; falling back to a temp path." >&2
  DERIVED="${TMPDIR:-/tmp}/devstation-derived"
  mkdir -p "$DERIVED"
fi

mkdir -p "$OUT_DIR"
mkdir -p "$BUILD_DIR"

if [[ "${CLEAN}" != "0" ]]; then
  echo "Cleaning Dev Station..."
  /usr/bin/xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    clean
fi

echo "Building Dev Station..."
/usr/bin/xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED" \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  build

BUILD_APP="$BUILD_DIR/$APP_NAME"
if [[ ! -d "$BUILD_APP" ]]; then
  echo "devstation-build: app not found at $BUILD_APP" >&2
  exit 2
fi

PLIST_PATH="$BUILD_APP/Contents/Info.plist"
if [[ ! -f "$PLIST_PATH" ]]; then
  echo "devstation-build: Info.plist missing at $PLIST_PATH" >&2
  exit 2
fi

if /usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST_PATH" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable DevStation" "$PLIST_PATH"
else
  /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string DevStation" "$PLIST_PATH"
fi

if /usr/libexec/PlistBuddy -c "Print :CFBundleName" "$PLIST_PATH" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $PLIST_NAME" "$PLIST_PATH"
else
  /usr/libexec/PlistBuddy -c "Add :CFBundleName string $PLIST_NAME" "$PLIST_PATH"
fi

if ! validate_app_bundle "$BUILD_APP"; then
  echo "devstation-build: invalid app bundle at $BUILD_APP" >&2
  exit 2
fi

rm -rf "$OUT_DIR/$APP_NAME"
/usr/bin/ditto "$BUILD_APP" "$OUT_DIR/$APP_NAME"

if command -v codesign >/dev/null 2>&1; then
  /usr/bin/codesign --force --sign - "$OUT_DIR/$APP_NAME" || true
fi

if ! validate_app_bundle "$OUT_DIR/$APP_NAME"; then
  echo "devstation-build: invalid app bundle at $OUT_DIR/$APP_NAME" >&2
  exit 2
fi

echo "Built: $OUT_DIR/$APP_NAME"
