#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TARGETS_FILE="${1:-${FED_TARGETS_FILE:-$REPO_ROOT/ops/strangelab-control-plane/config/federation-targets.json}}"

if [[ ! -f "$TARGETS_FILE" ]]; then
  echo "[FAIL] federation targets file missing: $TARGETS_FILE"
  exit 2
fi

python3 - "$TARGETS_FILE" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
required_actions = [
    "node.claim",
    "node.flash",
    "node.health.request",
    "panic.freeze.agents",
    "panic.lockdown.egress",
    "panic.isolate.node",
    "panic.kill.switch",
    "snapshot.now",
    "snapshot.services",
    "snapshot.net.routes",
    "snapshot.vault.verify",
    "maint.restart.service",
    "maint.status.service",
    "maint.logs.tail",
    "maint.disk.df",
    "maint.net.ping",
    "scan.lan.fast",
    "scan.lan.ports.top",
    "scan.ble.sweep",
    "scan.wifi.snapshot",
    "build.version.report",
    "build.flash.target",
    "build.rollback.target",
    "build.deploy.config",
    "ritual.rollcall",
    "ritual.heartbeat.burst",
    "ritual.quiet.mode",
    "ritual.wake.mode",
]

try:
    data = json.loads(path.read_text())
except Exception as exc:
    print(f"[FAIL] invalid JSON in {path}: {exc}")
    sys.exit(2)

if not isinstance(data, dict):
    print(f"[FAIL] federation targets must be a JSON object: {path}")
    sys.exit(2)

defaults = data.get("defaults")
actions = data.get("actions")
schema = str(data.get("schema_version", "")).strip()

if not schema:
    print("[FAIL] missing schema_version in federation targets")
    sys.exit(2)

if not isinstance(defaults, dict):
    print("[FAIL] defaults must be an object in federation targets")
    sys.exit(2)

if not isinstance(actions, dict):
    print("[FAIL] actions must be an object in federation targets")
    sys.exit(2)

default_dispatch = str(defaults.get("dispatch_op", "")).strip()
if default_dispatch not in {"dispatch.intent", "dispatch.tool"}:
    print("[FAIL] defaults.dispatch_op must be dispatch.intent or dispatch.tool")
    sys.exit(2)

missing = [action for action in required_actions if action not in actions]
if missing:
    print("[FAIL] unmapped federation actions:")
    for action in missing:
        print(f"  - {action}")
    sys.exit(2)

invalid = []
for action, rule in actions.items():
    if not isinstance(rule, dict):
        invalid.append(f"{action}: rule must be object")
        continue
    dispatch = rule.get("dispatch")
    if dispatch is None:
        continue
    if not isinstance(dispatch, dict):
        invalid.append(f"{action}: dispatch must be object")
        continue
    has_tool = isinstance(dispatch.get("tool"), str) and dispatch["tool"].strip()
    has_intent = isinstance(dispatch.get("intent"), str) and dispatch["intent"].strip()
    if not has_tool and not has_intent:
        invalid.append(f"{action}: dispatch must include tool or intent")

if invalid:
    print("[FAIL] invalid federation action mappings:")
    for row in invalid:
        print(f"  - {row}")
    sys.exit(2)

print(f"[PASS] federation targets validated ({len(required_actions)} required actions, schema={schema})")
PY
