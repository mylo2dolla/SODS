#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$REPO_ROOT/data/logs"
PORT="9123"
PI_LOGGER="http://pi-logger.local:8088"

mkdir -p "$LOG_DIR"

echo "Building Dev Station..."
"$REPO_ROOT/tools/devstation-build.sh"
source "$REPO_ROOT/tools/_app_bundle.sh"

echo "Validating Dev Station app bundle..."
validate_app_bundle "$REPO_ROOT/dist/DevStation.app"

if ! curl -fsS "http://localhost:${PORT}/api/status" >/dev/null 2>&1; then
  echo "Starting station on http://localhost:${PORT}"
  nohup "$REPO_ROOT/tools/sods" start --pi-logger "$PI_LOGGER" --port "$PORT" >>"$LOG_DIR/station.smoke.log" 2>&1 &
  sleep 1
fi

echo "Checking /api/status"
curl -fsS "http://localhost:${PORT}/api/status" | head -n 5
echo "Checking /api/tools"
curl -fsS "http://localhost:${PORT}/api/tools" | head -n 5
echo "Checking /api/nodes"
curl -fsS "http://localhost:${PORT}/api/nodes" | head -n 5
echo "Checking /api/flash"
curl -fsS "http://localhost:${PORT}/api/flash"
echo "Checking /api/presets"
curl -fsS "http://localhost:${PORT}/api/presets" | head -n 5
echo "Checking /api/runbooks"
curl -fsS "http://localhost:${PORT}/api/runbooks" | head -n 5

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
