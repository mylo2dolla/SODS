#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/_env.sh"
LOG_DIR="$REPO_ROOT/data/logs"
PORT="${PORT:-$SODS_PORT}"
PI_LOGGER="${PI_LOGGER:-$PI_LOGGER_URL}"
STATION_URL="${SODS_STATION_URL:-http://127.0.0.1:${PORT}}"

mkdir -p "$LOG_DIR"

echo "Building Dev Station..."
SODS_SKIP_FIRMWARE_CHECK="${SODS_SKIP_FIRMWARE_CHECK:-1}" "$REPO_ROOT/tools/devstation-build.sh"
source "$REPO_ROOT/tools/_app_bundle.sh"

echo "Validating Dev Station app bundle..."
validate_app_bundle "$REPO_ROOT/dist/DevStation.app"

if ! curl -fsS "${STATION_URL%/}/api/status" >/dev/null 2>&1; then
  echo "Starting station on ${STATION_URL%/}"
  nohup "$REPO_ROOT/tools/sods" start --pi-logger "$PI_LOGGER" --port "$PORT" >>"$LOG_DIR/station.smoke.log" 2>&1 &
  sleep 1
fi

echo "Checking /api/status"
curl -fsS "${STATION_URL%/}/api/status" | head -n 5
echo "Checking /api/tools"
curl -fsS "${STATION_URL%/}/api/tools" | head -n 5
echo "Checking /api/nodes"
curl -fsS "${STATION_URL%/}/api/nodes" | head -n 5
echo "Checking /api/flash"
curl -fsS "${STATION_URL%/}/api/flash"
echo "Checking /api/presets"
curl -fsS "${STATION_URL%/}/api/presets" | head -n 5
echo "Checking /api/runbooks"
curl -fsS "${STATION_URL%/}/api/runbooks" | head -n 5

echo "Audit: internal URLs should not use NSWorkspace.open (flash is allowed)"
HTTP_OPENS="$(rg -n "NSWorkspace\\.shared\\.open\\(.*http" "$REPO_ROOT/apps/dev-station/DevStation" || true)"
if [[ -n "$HTTP_OPENS" ]]; then
  DISALLOWED="$(echo "$HTTP_OPENS" | rg -v "/flash/")"
  if [[ -n "$DISALLOWED" ]]; then
    echo "Found external http opens outside /flash/ in Dev Station Swift files."
    echo "$DISALLOWED"
    exit 2
  fi
fi

echo "Audit: modal sheets should include ModalHeaderView"
REQUIRED_SHEETS=(
  "ToolRegistryView.swift"
  "APIInspectorView.swift"
  "ToolRunnerView.swift"
  "PresetRunnerView.swift"
  "RunbookRunnerView.swift"
  "ToolBuilderView.swift"
  "PresetBuilderView.swift"
  "ScratchpadView.swift"
  "AliasManagerView.swift"
  "FindDeviceView.swift"
  "ViewerSheet.swift"
)
for sheet in "${REQUIRED_SHEETS[@]}"; do
  if ! rg -n "ModalHeaderView" "$REPO_ROOT/apps/dev-station/DevStation/$sheet" >/dev/null 2>&1; then
    echo "Missing ModalHeaderView in $sheet"
    exit 3
  fi
done
