#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/../../.." && pwd)"

APP_RUNTIME_DIR="$REPO_ROOT/apps/dev-station/DevStation"
PKG_RUNTIME_DIR="$WORKSPACE_ROOT/LvlUpKit.package/Sources/LvlUpKitSODSInternal"

if [[ ! -d "$APP_RUNTIME_DIR" ]]; then
  echo "check-dynamic-data: missing runtime dir: $APP_RUNTIME_DIR" >&2
  exit 2
fi

RUNTIME_DIRS=("$APP_RUNTIME_DIR")
if [[ ! -d "$PKG_RUNTIME_DIR" ]]; then
  echo "check-dynamic-data: missing package runtime dir: $PKG_RUNTIME_DIR (skipping)" >&2
else
  RUNTIME_DIRS+=("$PKG_RUNTIME_DIR")
fi

# Allowed static identity maps (non-runtime fake data).
ALLOWLIST_FILES=(
  "$APP_RUNTIME_DIR/Resources/OUI.txt"
  "$APP_RUNTIME_DIR/Resources/BLECompanyIDs.txt"
  "$APP_RUNTIME_DIR/Resources/BLEAssignedNumbers.txt"
  "$APP_RUNTIME_DIR/Resources/BLEServiceUUIDs.txt"
)

PATTERN='placeholder|(^|[^a-z])mock([^a-z]|$)|(^|[^a-z])fake([^a-z]|$)|(^|[^a-z])dummy([^a-z]|$)|hardcoded|hard-coded|sample[[:space:]_-]*data|test[[:space:]_-]*data'

echo "Running dynamic-data compliance checks..."
echo "  app: $APP_RUNTIME_DIR"
if [[ -d "$PKG_RUNTIME_DIR" ]]; then
  echo "  pkg: $PKG_RUNTIME_DIR"
fi

for allowed in "${ALLOWLIST_FILES[@]}"; do
  if [[ ! -f "$allowed" ]]; then
    echo "check-dynamic-data: warning: allowlisted file not found: $allowed" >&2
  fi
done

if command -v rg >/dev/null 2>&1; then
  MATCH_CMD=(rg -n -i --pcre2 "$PATTERN"
    "${RUNTIME_DIRS[@]}"
    --glob '!**/Resources/OUI.txt'
    --glob '!**/Resources/BLECompanyIDs.txt'
    --glob '!**/Resources/BLEAssignedNumbers.txt'
    --glob '!**/Resources/BLEServiceUUIDs.txt'
    --glob '!**/*.xcodeproj/**'
    --glob '!**/xcuserdata/**'
    --glob '!**/*.xcuserstate'
    --glob '!**/node_modules/**'
    --glob '!**/dist/**'
    --glob '!**/.build/**'
    --glob '!**/.run/**'
    --glob '!**/tests/**'
    --glob '!**/Tests/**')
else
  MATCH_CMD=(grep -RInE "$PATTERN"
    "${RUNTIME_DIRS[@]}"
    --exclude='OUI.txt'
    --exclude='BLECompanyIDs.txt'
    --exclude='BLEAssignedNumbers.txt'
    --exclude='BLEServiceUUIDs.txt'
    --exclude-dir='*.xcodeproj'
    --exclude-dir='xcuserdata'
    --exclude-dir='node_modules'
    --exclude-dir='dist'
    --exclude-dir='.build'
    --exclude-dir='.run'
    --exclude-dir='tests'
    --exclude-dir='Tests')
fi

if "${MATCH_CMD[@]}"; then
  echo
  echo "Dynamic-data compliance FAILED." >&2
  echo "Found forbidden placeholder/mock/fake/hardcoded patterns in runtime sources." >&2
  exit 1
fi

echo "Dynamic-data compliance OK."
