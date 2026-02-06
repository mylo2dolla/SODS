#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$REPO_ROOT/apps/dev-station/DevStation.xcodeproj"
SCHEME="DevStation"
DERIVED="$REPO_ROOT/dist/DerivedData"
OUT_DIR="$REPO_ROOT/dist"
APP_NAME="DevStation.app"

if [[ ! -d "$PROJECT" ]]; then
  echo "devstation-build: project not found at $PROJECT" >&2
  exit 2
fi

mkdir -p "$OUT_DIR"

echo "Building Dev Station..."
/usr/bin/xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build

BUILD_APP="$DERIVED/Build/Products/Release/$APP_NAME"
if [[ ! -d "$BUILD_APP" ]]; then
  echo "devstation-build: app not found at $BUILD_APP" >&2
  exit 2
fi

rm -rf "$OUT_DIR/$APP_NAME"
/usr/bin/ditto "$BUILD_APP" "$OUT_DIR/$APP_NAME"

if command -v codesign >/dev/null 2>&1; then
  /usr/bin/codesign --force --sign - "$OUT_DIR/$APP_NAME" || true
fi

echo "Built: $OUT_DIR/$APP_NAME"
