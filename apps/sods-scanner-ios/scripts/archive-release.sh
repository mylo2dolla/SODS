#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

"$ROOT_DIR/scripts/validate-signing.sh"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARCHIVE_PATH="${1:-$ROOT_DIR/build/SODSScanneriOS-$TIMESTAMP.xcarchive}"
mkdir -p "$(dirname "$ARCHIVE_PATH")"

xcodebuild \
  -project SODSScanneriOS.xcodeproj \
  -scheme SODSScanneriOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  ${DEVELOPMENT_TEAM_OVERRIDE:+DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM_OVERRIDE} \
  archive

echo "[PASS] Archive created at: $ARCHIVE_PATH"
