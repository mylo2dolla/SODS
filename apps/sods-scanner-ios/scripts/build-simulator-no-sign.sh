#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
cd "$ROOT_DIR"

"$REPO_ROOT/tools/verify-app-icons.sh" --target scanner-ios

xcodebuild \
  -project SODSScanneriOS.xcodeproj \
  -scheme SODSScanneriOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
