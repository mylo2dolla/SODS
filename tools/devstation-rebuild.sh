#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/_env.sh"

APP_NAME="Dev Station"
APP_BUNDLE="/Applications/${APP_NAME}.app"
DERIVED_DATA="${REPO_ROOT}/dist/DerivedData"
BUILD_DIR="${REPO_ROOT}/dist/build"
OUT_APP="${REPO_ROOT}/dist/DevStation.app"
PROJECT="${REPO_ROOT}/apps/dev-station/DevStation.xcodeproj"
SCHEME="DevStation"
PORT="${PORT:-$SODS_PORT}"
PI_LOGGER="${PI_LOGGER:-$PI_LOGGER_URL}"
LOG_DIR="$HOME/Library/Logs/SODS"
LOG_FILE="$LOG_DIR/station.log"

pkill -x "DevStation" >/dev/null 2>&1 || true
pkill -x "Dev Station" >/dev/null 2>&1 || true
pkill -x "DevStationApp" >/dev/null 2>&1 || true

if command -v lsof >/dev/null 2>&1; then
  PIDS="$(lsof -ti tcp:${PORT} || true)"
  if [ -n "${PIDS}" ]; then
    kill ${PIDS} >/dev/null 2>&1 || true
  fi
fi

if [ -d "${DERIVED_DATA}" ]; then
  rm -rf "${DERIVED_DATA}"
fi
if [ -d "${BUILD_DIR}" ]; then
  rm -rf "${BUILD_DIR}"
fi
if [ -d "${OUT_APP}" ]; then
  rm -rf "${OUT_APP}"
fi

if [ -d "${PROJECT}" ]; then
  echo "Cleaning Dev Station..."
  /usr/bin/xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -derivedDataPath "${DERIVED_DATA}" \
    CODE_SIGNING_ALLOWED=NO \
    clean
fi

DEVSTATION_CLEAN=1 "${REPO_ROOT}/tools/devstation-build.sh"
"${REPO_ROOT}/tools/devstation-install.sh"

if [ -d "${APP_BUNDLE}" ]; then
  :
fi

mkdir -p "$LOG_DIR"
STATION_URL="${SODS_STATION_URL:-http://127.0.0.1:${PORT}}"
if ! curl -fsS "${STATION_URL%/}/api/status" >/dev/null 2>&1; then
  "$REPO_ROOT/tools/station" start
fi

echo "Launching Dev Station..."
open "${APP_BUNDLE}"

echo "Dev Station rebuild complete (clean + build + install + station + launch)."
