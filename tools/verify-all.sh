#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_env.sh"

fail=0
LOCAL_STATION_URL="${SODS_LOCAL_STATION_URL:-http://127.0.0.1:${SODS_PORT:-9123}}"
CONTROL_PLANE_OK=0

pass() { printf '[PASS] %s\n' "$1"; }
fail_msg() { printf '[FAIL] %s\n' "$1"; fail=1; }
section() { printf '\n== %s ==\n' "$1"; }

json_has_ok_true() {
  local payload="$1"
  python3 - "$payload" <<'PY'
import json, sys
text = sys.argv[1]
try:
    obj = json.loads(text)
except Exception:
    sys.exit(1)
sys.exit(0 if obj.get("ok") is True else 1)
PY
}

json_count_gt_zero() {
  local payload="$1"
  python3 - "$payload" <<'PY'
import json, sys
text = sys.argv[1]
try:
    obj = json.loads(text)
except Exception:
    sys.exit(1)
count = obj.get("count", 0)
try:
    ok = int(count) > 0
except Exception:
    ok = False
sys.exit(0 if ok else 1)
PY
}

request_id() {
  printf '%s-%s' "$1" "$(date +%s)-$RANDOM"
}

section "0) App Icon Integrity"
if "$SCRIPT_DIR/verify-app-icons.sh" --target all >/dev/null 2>&1; then
  pass "app icon assets and project wiring verified"
else
  fail_msg "app icon verification failed (run tools/verify-app-icons.sh --target all)"
fi

section "A) Network"
if ping -c 1 "$AUX_HOST" >/dev/null 2>&1; then
  pass "pi-aux reachable (${AUX_HOST})"
else
  fail_msg "pi-aux unreachable (${AUX_HOST})"
fi
if ping -c 1 "$LOGGER_HOST" >/dev/null 2>&1; then
  pass "pi-logger reachable (${LOGGER_HOST})"
else
  fail_msg "pi-logger unreachable (${LOGGER_HOST})"
fi

section "B) Vault Ingest"
vault_probe='{"type":"vault.verify_all","src":"verify-all","ts_ms":0,"data":{"ok":true}}'
if curl --max-time 8 -fsS -X POST "$VAULT_URL" -H 'content-type: application/json' -d "$vault_probe" >/dev/null; then
  pass "vault ingest reachable"
else
  fail_msg "vault ingest failed (${VAULT_URL})"
fi

section "C) Federation Contract"
if "$SCRIPT_DIR/verify-federation-contract.sh" >/dev/null 2>&1; then
  pass "federation contract validates"
else
  fail_msg "federation contract validation failed"
fi

section "D) Control Plane"
if "$SCRIPT_DIR/verify-control-plane.sh" >/dev/null 2>&1; then
  pass "control-plane verify script passed"
  CONTROL_PLANE_OK=1
else
  fail_msg "control-plane verify script failed"
fi

section "E) Trace + Dedupe"
dry_id="$(request_id verify-dry)"
dry_rsp="$(curl --max-time 8 -sS -X POST "$GOD_URL" -H 'content-type: application/json' -d "{\"action\":\"snapshot.now\",\"scope\":\"tier1\",\"target\":null,\"request_id\":\"${dry_id}\",\"reason\":\"verify-all-dry\",\"ts_ms\":0,\"args\":{\"dry_run\":true}}" || true)"
if json_has_ok_true "$dry_rsp"; then
  pass "dry-run action accepted"
else
  fail_msg "dry-run action rejected"
fi

dry_trace_rsp="$(curl --max-time 8 -fsS "${OPS_FEED_URL}/trace?request_id=${dry_id}&limit=120&scan_limit=260&since_ms=$(( $(date +%s) * 1000 - 1200000 ))" || true)"
if printf '%s' "$dry_trace_rsp" | rg -q 'control\.god_button\.(intent|result)'; then
  pass "trace lookup returned dry-run control events"
else
  fail_msg "trace lookup missing dry-run control events"
fi

dup_id="$(request_id verify-dedupe)"
first_rsp="$(curl --max-time 8 -sS -X POST "$GOD_URL" -H 'content-type: application/json' -d "{\"action\":\"snapshot.now\",\"scope\":\"tier1\",\"target\":null,\"request_id\":\"${dup_id}\",\"reason\":\"verify-first\",\"ts_ms\":0,\"args\":{}}" || true)"
second_rsp="$(curl --max-time 8 -sS -X POST "$GOD_URL" -H 'content-type: application/json' -d "{\"action\":\"snapshot.now\",\"scope\":\"tier1\",\"target\":null,\"request_id\":\"${dup_id}\",\"reason\":\"verify-duplicate\",\"ts_ms\":0,\"args\":{}}" || true)"
if json_has_ok_true "$first_rsp"; then
  pass "first request accepted"
else
  fail_msg "first request was not accepted"
fi
if python3 - "$second_rsp" <<'PY'
import json, sys
text = sys.argv[1]
try:
    obj = json.loads(text)
except Exception:
    sys.exit(1)
msg = json.dumps(obj).lower()
if obj.get("ok") is False or "duplicate" in msg:
    sys.exit(0)
sys.exit(1)
PY
then
  pass "duplicate request_id denied"
else
  fail_msg "duplicate request_id was not denied"
fi

trace_rsp="$(curl --max-time 8 -fsS "${OPS_FEED_URL}/trace?request_id=${dup_id}&limit=200&scan_limit=320&since_ms=$(( $(date +%s) * 1000 - 1200000 ))" || true)"
if json_count_gt_zero "$trace_rsp"; then
  pass "trace returns routed events for request_id"
else
  fail_msg "trace missing events for request_id"
fi

section "F) Event Feed Evidence"
events_rsp="$(curl --max-time 8 -fsS "${OPS_FEED_URL}/events?limit=160&typePrefix=control.god_button&since_ms=$(( $(date +%s) * 1000 - 900000 ))" || true)"
if json_count_gt_zero "$events_rsp"; then
  pass "recent control.god_button events visible in ops-feed"
else
  fail_msg "no recent control.god_button events visible in ops-feed"
fi

section "G) SSH Guard"
if "$SCRIPT_DIR/verify-ssh-guard.sh" >/dev/null 2>&1; then
  pass "ssh guard verify script passed"
else
  fail_msg "ssh guard verify script failed"
fi

section "H) Local Core Node Presence"
local_nodes_payload="$(curl --max-time 8 -fsS "${LOCAL_STATION_URL%/}/api/nodes" || true)"
if [[ "$CONTROL_PLANE_OK" -eq 1 ]]; then
if presence_result="$(python3 - "$local_nodes_payload" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    payload = json.loads(raw)
except Exception:
    print("api/nodes not parseable")
    sys.exit(1)
items = payload.get("items")
if not isinstance(items, list):
    print("api/nodes missing items[]")
    sys.exit(1)
core_ids = ["exec-pi-aux", "exec-pi-logger", "mac16"]
rows = {}
for row in items:
    if not isinstance(row, dict):
        continue
    node_id = row.get("node_id")
    if node_id in core_ids:
        rows[node_id] = row
missing = [node for node in core_ids if node not in rows]
if missing:
    print("missing core nodes: " + ",".join(missing))
    sys.exit(1)
all_stale = all(
    str(rows[node].get("state", "")).lower() == "offline"
    and str(rows[node].get("state_reason", "")).lower() == "stale-events"
    for node in core_ids
)
if all_stale:
    detail = "; ".join(
        f"{node}={rows[node].get('state','')}/{rows[node].get('state_reason','')}/{rows[node].get('presence_source','')}"
        for node in core_ids
    )
    print("all core nodes stale-offline: " + detail)
    sys.exit(1)
summary = "; ".join(
    f"{node}={rows[node].get('state','')}/{rows[node].get('state_reason','')}/{rows[node].get('presence_source','')}"
    for node in core_ids
)
print(summary)
PY
)"; then
  pass "local core node presence is healthy (${presence_result})"
else
  fail_msg "local core node presence mismatch (${presence_result:-check failed})"
fi
else
if presence_result="$(python3 - "$local_nodes_payload" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    payload = json.loads(raw)
except Exception:
    print("api/nodes not parseable")
    sys.exit(1)
items = payload.get("items")
if not isinstance(items, list):
    print("api/nodes missing items[]")
    sys.exit(1)
core_ids = ["exec-pi-aux", "exec-pi-logger", "mac16"]
rows = {}
for row in items:
    if isinstance(row, dict) and row.get("node_id") in core_ids:
        rows[row["node_id"]] = row
missing = [node for node in core_ids if node not in rows]
if missing:
    print("missing core nodes: " + ",".join(missing))
    sys.exit(1)
summary = "; ".join(
    f"{node}={rows[node].get('state','')}/{rows[node].get('state_reason','')}/{rows[node].get('presence_source','')}"
    for node in core_ids
)
print(summary)
PY
)"; then
  pass "local core nodes present (control-plane degraded, strict stale-state gate skipped: ${presence_result})"
else
  fail_msg "local core node presence check failed (${presence_result:-check failed})"
fi
fi

section "I) UI Data Rules"
if "$SCRIPT_DIR/verify-ui-data.sh" >/dev/null 2>&1; then
  pass "ui-data verify script passed"
else
  fail_msg "ui-data verify script failed"
fi

if [[ "$fail" -eq 0 ]]; then
  echo
  echo "verify-all: PASS"
  exit 0
fi

echo
echo "verify-all: FAIL"
exit 2
