#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_VIS="$REPO_ROOT/apps/dev-station/DevStation/VisualizerView.swift"
APP_VIS_COMPONENTS="$REPO_ROOT/apps/dev-station/DevStation/VisualizerComponents.swift"
PKG_VIS=""

resolve_workspace_root() {
  if [[ -n "${SODS_WORKSPACE_ROOT:-}" ]]; then
    local override="$SODS_WORKSPACE_ROOT"
    if [[ -d "$override/LvlUpKit.package" ]]; then
      (cd "$override" && pwd)
      return 0
    fi
    if [[ "$(basename "$override")" == "LvlUpKit.package" && -d "$override" ]]; then
      (cd "$override/.." && pwd)
      return 0
    fi
    echo "verify-ui-data: SODS_WORKSPACE_ROOT does not contain LvlUpKit.package: $override (package visualizer checks skipped)" >&2
    return 1
  fi

  local sibling_package="$REPO_ROOT/../LvlUpKit.package"
  if [[ -d "$sibling_package" ]]; then
    (cd "$REPO_ROOT/.." && pwd)
    return 0
  fi

  echo "verify-ui-data: missing optional package at $sibling_package (package visualizer checks skipped)" >&2
  return 1
}

if WORKSPACE_ROOT="$(resolve_workspace_root)"; then
  candidate="$WORKSPACE_ROOT/LvlUpKit.package/Sources/LvlUpKitSODSInternal/VisualizerView.swift"
  if [[ -f "$candidate" ]]; then
    PKG_VIS="$candidate"
  else
    echo "verify-ui-data: package visualizer file missing: $candidate (package visualizer checks skipped)" >&2
  fi
fi

fail=0

pass() { printf '[PASS] %s\n' "$1"; }
fail_msg() { printf '[FAIL] %s\n' "$1"; fail=1; }

must_contain_in_files() {
  local label="$1"
  local pattern="$2"
  shift 2
  if rg -n "$pattern" "$@" >/dev/null 2>&1; then
    pass "$label"
  else
    fail_msg "$label"
  fi
}

verify_visualizer_contract() {
  local label="$1"
  shift
  must_contain_in_files "$label defines SpectrumSignalType" 'enum SpectrumSignalType' "$@"
  must_contain_in_files "$label CONTROL mapping present" 'case control = "CONTROL"' "$@"
  must_contain_in_files "$label EVENT mapping present" 'case event = "EVENT"' "$@"
  must_contain_in_files "$label EVIDENCE mapping present" 'case evidence = "EVIDENCE"' "$@"
  must_contain_in_files "$label MEDIA mapping present" 'case media = "MEDIA"' "$@"
  must_contain_in_files "$label MGMT mapping present" 'case mgmt = "MGMT"' "$@"
  must_contain_in_files "$label control event mapping present" 'control\.god_button|kind\.contains\("god_button"\)' "$@"
  must_contain_in_files "$label mgmt event mapping present" 'agent\.exec|agent\.ssh' "$@"
  must_contain_in_files "$label event mapping present" 'node\.health|kind\.contains\("ble"\)|kind\.contains\("wifi"\)' "$@"
  must_contain_in_files "$label evidence mapping present" 'kind\.contains\("vault"\)|kind\.contains\("ingest"\)' "$@"
  must_contain_in_files "$label websocket transport style present" 'case \.live[a-zA-Z]+' "$@"
  must_contain_in_files "$label SSH transport style present" 'case \.ssh' "$@"
  must_contain_in_files "$label BLE transport style present" 'case \.ble' "$@"
  must_contain_in_files "$label Wi-Fi passive transport style present" 'case \.wifiPassive' "$@"
  must_contain_in_files "$label serial transport style present" 'case \.serial' "$@"
  must_contain_in_files "$label edge hit test present" 'func nearestEdge' "$@"
  must_contain_in_files "$label edge hover tooltip present" 'EdgeHoverTooltipView' "$@"
  must_contain_in_files "$label edge trace panel present" 'EdgeTracePanelView' "$@"
  must_contain_in_files "$label throttled animation present" 'minimumInterval: 1\.0 / (15|30)\.0' "$@"
}

echo "== J) Spectrum UI + Dynamic Data =="

if "$REPO_ROOT/tools/check-visualizer-sync.sh" >/dev/null 2>&1; then
  pass "visualizer package/app sync check passes"
else
  fail_msg "visualizer package/app sync check failed"
fi

if "$REPO_ROOT/tools/check-dynamic-data.sh" >/dev/null 2>&1; then
  pass "dynamic-data compliance passes"
else
  fail_msg "dynamic-data compliance failed"
fi

if "$REPO_ROOT/tools/check-ble-metadata.sh" >/dev/null 2>&1; then
  pass "BLE metadata coverage passes"
else
  fail_msg "BLE metadata coverage failed"
fi

if "$REPO_ROOT/tools/check-devstation-performance.sh" >/dev/null 2>&1; then
  pass "Dev Station no-regression performance gate passes"
else
  fail_msg "Dev Station no-regression performance gate failed"
fi

if [[ -n "$PKG_VIS" ]]; then
  verify_visualizer_contract "$PKG_VIS" "$PKG_VIS"
else
  pass "package visualizer optional target skipped"
fi

if [[ ! -f "$APP_VIS" ]]; then
  fail_msg "app visualizer missing: $APP_VIS"
else
  app_visualizer_files=("$APP_VIS")
  if [[ -f "$APP_VIS_COMPONENTS" ]]; then
    app_visualizer_files+=("$APP_VIS_COMPONENTS")
  fi
  verify_visualizer_contract "app visualizer contract" "${app_visualizer_files[@]}"
fi

if [[ "$fail" -eq 0 ]]; then
  echo "verify-ui-data: PASS"
  exit 0
fi
echo "verify-ui-data: FAIL"
exit 2
