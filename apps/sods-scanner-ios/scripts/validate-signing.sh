#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
cd "$ROOT_DIR"

PROJECT="SODSScanneriOS.xcodeproj"
SCHEME="SODSScanneriOS"

"$REPO_ROOT/tools/verify-app-icons.sh" --target scanner-ios

function build_settings_for() {
  local config="$1"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$config" \
    -destination "generic/platform=iOS" \
    -showBuildSettings
}

function require_contains() {
  local haystack="$1"
  local needle="$2"
  local description="$3"
  if ! grep -Fq "$needle" <<<"$haystack"; then
    echo "[FAIL] Missing $description ($needle)" >&2
    exit 1
  fi
}

DEBUG_SETTINGS="$(build_settings_for Debug)"
RELEASE_SETTINGS="$(build_settings_for Release)"

require_contains "$DEBUG_SETTINGS" "CODE_SIGN_STYLE = Automatic" "automatic signing in Debug"
require_contains "$RELEASE_SETTINGS" "CODE_SIGN_STYLE = Automatic" "automatic signing in Release"
require_contains "$DEBUG_SETTINGS" "PRODUCT_BUNDLE_IDENTIFIER = com.strangelab.sods.scanner.dev.letsdev23" "bundle id in Debug"
require_contains "$RELEASE_SETTINGS" "PRODUCT_BUNDLE_IDENTIFIER = com.strangelab.sods.scanner" "bundle id in Release"
require_contains "$DEBUG_SETTINGS" "CODE_SIGN_ENTITLEMENTS = SODSScanneriOS/Resources/SODSScanneriOS.Debug.entitlements" "debug entitlements"
require_contains "$RELEASE_SETTINGS" "CODE_SIGN_ENTITLEMENTS = SODSScanneriOS/Resources/SODSScanneriOS.entitlements" "release entitlements"
require_contains "$RELEASE_SETTINGS" "MARKETING_VERSION = 1.0.0" "marketing version"
require_contains "$RELEASE_SETTINGS" "CURRENT_PROJECT_VERSION = 1" "project build version"

TEAM_ID="$(awk -F' = ' '/DEVELOPMENT_TEAM = / {print $2; exit}' <<<"$RELEASE_SETTINGS" | tr -d '[:space:]')"
if [[ -z "$TEAM_ID" || "$TEAM_ID" == "\"\"" ]]; then
  if [[ -n "${DEVELOPMENT_TEAM_OVERRIDE:-}" ]]; then
    TEAM_ID="${DEVELOPMENT_TEAM_OVERRIDE}"
    echo "[INFO] Using DEVELOPMENT_TEAM_OVERRIDE=$TEAM_ID"
  else
    echo "[FAIL] DEVELOPMENT_TEAM is empty for Release. Set your team in Xcode before archiving, or pass DEVELOPMENT_TEAM_OVERRIDE." >&2
    exit 1
  fi
fi

echo "[PASS] Signing settings validated for Debug and Release."
