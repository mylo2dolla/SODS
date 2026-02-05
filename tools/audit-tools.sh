#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY="$REPO_ROOT/docs/tool-registry.json"

if [[ ! -f "$REGISTRY" ]]; then
  echo "tool registry not found: $REGISTRY" >&2
  exit 2
fi

python3 -c 'import json,sys; path=sys.argv[1]; data=json.load(open(path,"r")); tools={t["name"] for t in data.get("tools",[]) if "name" in t}; expected={"camera.viewer","net.arp","net.dhcp_packet","net.dns_timing","net.wifi_scan","net.status_snapshot","net.whoami_rollcall","portal.flash_targets","station.portal_state","station.frames_health","ble.rssi_trend","ble.scan_snapshot","events.activity_snapshot","events.replay"}; missing=sorted(expected-tools); extra=sorted(tools-expected); print("Tool registry audit"); print(f"Total tools: {len(tools)}"); print("Missing tools:"); print("\\n".join([f"  - {n}" for n in missing]) if missing else "  none"); print("Extra tools (not in expected set):"); print("\\n".join([f"  - {n}" for n in extra]) if extra else "  none")' "$REGISTRY"
