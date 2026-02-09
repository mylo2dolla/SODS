#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/../../.." && pwd)"

PKG_VIS="$WORKSPACE_ROOT/LvlUpKit.package/Sources/LvlUpKitSODSInternal/VisualizerView.swift"
APP_VIS="$REPO_ROOT/apps/dev-station/DevStation/VisualizerView.swift"

fail=0

pass() { printf '[PASS] %s\n' "$1"; }
fail_msg() { printf '[FAIL] %s\n' "$1"; fail=1; }

must_contain() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if rg -n "$pattern" "$file" >/dev/null 2>&1; then
    pass "$label"
  else
    fail_msg "$label"
  fi
}

verify_visualizer_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    pass "$file missing (optional target, skipped)"
    return
  fi
  must_contain "$file" 'enum SpectrumSignalType' "$file defines SpectrumSignalType"
  must_contain "$file" 'case control = "CONTROL"' "$file CONTROL mapping present"
  must_contain "$file" 'case event = "EVENT"' "$file EVENT mapping present"
  must_contain "$file" 'case evidence = "EVIDENCE"' "$file EVIDENCE mapping present"
  must_contain "$file" 'case media = "MEDIA"' "$file MEDIA mapping present"
  must_contain "$file" 'case mgmt = "MGMT"' "$file MGMT mapping present"
  must_contain "$file" 'control\.god_button|kind\.contains\("god_button"\)' "$file control event mapping present"
  must_contain "$file" 'agent\.exec|agent\.ssh' "$file mgmt event mapping present"
  must_contain "$file" 'node\.health|kind\.contains\("ble"\)|kind\.contains\("wifi"\)' "$file event mapping present"
  must_contain "$file" 'kind\.contains\("vault"\)|kind\.contains\("ingest"\)' "$file evidence mapping present"
  must_contain "$file" 'case \.livekit' "$file LiveKit transport style present"
  must_contain "$file" 'case \.ssh' "$file SSH transport style present"
  must_contain "$file" 'case \.ble' "$file BLE transport style present"
  must_contain "$file" 'case \.wifiPassive' "$file Wi-Fi passive transport style present"
  must_contain "$file" 'case \.serial' "$file serial transport style present"
  must_contain "$file" 'func nearestEdge' "$file edge hit test present"
  must_contain "$file" 'EdgeHoverTooltipView' "$file edge hover tooltip present"
  must_contain "$file" 'EdgeTracePanelView' "$file edge trace panel present"
  must_contain "$file" 'minimumInterval: 1\.0 / 15\.0' "$file throttled animation present"
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

verify_visualizer_file "$PKG_VIS"
verify_visualizer_file "$APP_VIS"

if [[ "$fail" -eq 0 ]]; then
  echo "verify-ui-data: PASS"
  exit 0
fi
echo "verify-ui-data: FAIL"
exit 2
