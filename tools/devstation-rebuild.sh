#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="Dev Station"
APP_BUNDLE="/Applications/${APP_NAME}.app"
DERIVED_DATA="${REPO_ROOT}/dist/DerivedData"

pkill -x "DevStation" >/dev/null 2>&1 || true
pkill -x "Dev Station" >/dev/null 2>&1 || true
pkill -x "DevStationApp" >/dev/null 2>&1 || true

if command -v lsof >/dev/null 2>&1; then
  PIDS="$(lsof -ti tcp:9123 || true)"
  if [ -n "${PIDS}" ]; then
    kill ${PIDS} >/dev/null 2>&1 || true
  fi
fi

if [ -d "${DERIVED_DATA}" ]; then
  rm -rf "${DERIVED_DATA}"
fi

"${REPO_ROOT}/tools/devstation-build.sh"
"${REPO_ROOT}/tools/devstation-install.sh"

if [ -d "${APP_BUNDLE}" ]; then
  open "${APP_BUNDLE}"
fi

echo "Dev Station rebuild complete."
