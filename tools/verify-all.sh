#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_env.sh"

fail=0

pass() { printf '[PASS] %s\n' "$1"; }
fail_msg() { printf '[FAIL] %s\n' "$1"; fail=1; }
section() { printf '\n== %s ==\n' "$1"; }

json_ok_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
text = sys.argv[1]
field = sys.argv[2]
try:
    obj = json.loads(text)
except Exception:
    sys.exit(2)
value = obj
for part in field.split("."):
    if not isinstance(value, dict) or part not in value:
        sys.exit(3)
    value = value[part]
if value is True:
    sys.exit(0)
sys.exit(1)
PY
}

json_field_nonempty() {
  python3 - "$1" "$2" <<'PY'
import json, sys
text = sys.argv[1]
field = sys.argv[2]
try:
    obj = json.loads(text)
except Exception:
    sys.exit(2)
value = obj
for part in field.split("."):
    if not isinstance(value, dict) or part not in value:
        sys.exit(3)
    value = value[part]
if value is None:
    sys.exit(1)
if isinstance(value, str):
    sys.exit(0 if value.strip() else 1)
if isinstance(value, (list, dict)):
    sys.exit(0 if len(value) > 0 else 1)
if isinstance(value, (int, float)):
    sys.exit(0 if value > 0 else 1)
sys.exit(1)
PY
}

request_id() {
  printf '%s-%s' "$1" "$(date +%s)-$RANDOM"
}

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

section "C) Control Plane + Feed"
token_rsp="$(curl --max-time 8 -fsS -X POST "$TOKEN_URL" -H 'content-type: application/json' -d '{"identity":"verify-all","room":"strangelab"}' || true)"
if json_field_nonempty "$token_rsp" "token"; then
  pass "token endpoint returned token"
else
  fail_msg "token endpoint invalid response"
fi

health_rsp="$(curl --max-time 8 -fsS "${OPS_FEED_URL}/health" || true)"
if json_ok_field "$health_rsp" "ok"; then
  pass "ops-feed health ok"
else
  fail_msg "ops-feed health failed"
fi

god_probe_id="$(request_id verify-gateway)"
god_probe_rsp="$(curl --max-time 8 -sS -X POST "$GOD_URL" -H 'content-type: application/json' -d "{\"action\":\"ritual.rollcall\",\"scope\":\"all\",\"target\":null,\"request_id\":\"${god_probe_id}\",\"reason\":\"verify-all\",\"ts_ms\":0,\"args\":{}}" || true)"
if json_ok_field "$god_probe_rsp" "ok"; then
  pass "god gateway accepts structured action"
else
  fail_msg "god gateway structured action failed"
fi

section "D) Agent Evidence"
exec_probe_id="$(request_id verify-exec)"
exec_probe_rsp="$(curl --max-time 8 -sS -X POST "$GOD_URL" -H 'content-type: application/json' -d "{\"action\":\"maint.status.service\",\"scope\":\"node\",\"target\":\"exec-pi-aux\",\"request_id\":\"${exec_probe_id}\",\"reason\":\"verify-agent-evidence\",\"ts_ms\":0,\"args\":{\"service\":\"strangelab-token.service\"}}" || true)"
if json_ok_field "$exec_probe_rsp" "ok"; then
  pass "maintenance probe action accepted"
else
  fail_msg "maintenance probe action failed"
fi
sleep 2

events_rsp="$(curl --max-time 8 -fsS "${OPS_FEED_URL}/events?limit=120&typePrefix=agent.exec.&since_ms=$(( $(date +%s) * 1000 - 900000 ))" || true)"
if json_field_nonempty "$events_rsp" "count"; then
  pass "recent agent.exec events visible in ops-feed"
else
  maint_events_rsp="$(curl --max-time 8 -fsS "${OPS_FEED_URL}/events?limit=120&typePrefix=node.maintenance.result&since_ms=$(( $(date +%s) * 1000 - 900000 ))" || true)"
  if json_field_nonempty "$maint_events_rsp" "count"; then
    pass "maintenance result events visible in ops-feed"
  else
    fail_msg "no recent command execution evidence visible in ops-feed"
  fi
fi

section "E) Vault-First Gate (Non-Destructive)"
dry_id="$(request_id verify-dry)"
dry_rsp="$(curl --max-time 8 -sS -X POST "$GOD_URL" -H 'content-type: application/json' -d "{\"action\":\"snapshot.now\",\"scope\":\"tier1\",\"target\":null,\"request_id\":\"${dry_id}\",\"reason\":\"verify-all-dry\",\"ts_ms\":0,\"args\":{\"dry_run\":true}}" || true)"
if json_ok_field "$dry_rsp" "ok"; then
  pass "dry-run action accepted while vault is reachable"
else
  fail_msg "dry-run action rejected unexpectedly"
fi

dry_trace_rsp="$(curl --max-time 8 -fsS "${OPS_FEED_URL}/trace?request_id=${dry_id}&limit=200&scan_limit=300&since_ms=$(( $(date +%s) * 1000 - 1200000 ))" || true)"
if json_field_nonempty "$dry_trace_rsp" "events"; then
  pass "trace lookup returned dry-run events"
else
  fail_msg "trace lookup missing dry-run events"
fi

section "F) Trace + Dedupe"
dup_id="$(request_id verify-dedupe)"
first_rsp="$(curl --max-time 8 -sS -X POST "$GOD_URL" -H 'content-type: application/json' -d "{\"action\":\"snapshot.now\",\"scope\":\"tier1\",\"target\":null,\"request_id\":\"${dup_id}\",\"reason\":\"verify-first\",\"ts_ms\":0,\"args\":{}}" || true)"
second_rsp="$(curl --max-time 8 -sS -X POST "$GOD_URL" -H 'content-type: application/json' -d "{\"action\":\"snapshot.now\",\"scope\":\"tier1\",\"target\":null,\"request_id\":\"${dup_id}\",\"reason\":\"verify-duplicate\",\"ts_ms\":0,\"args\":{}}" || true)"
if json_ok_field "$first_rsp" "ok"; then
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

trace_rsp="$(curl --max-time 8 -fsS "${OPS_FEED_URL}/trace?request_id=${dup_id}&limit=200&scan_limit=300&since_ms=$(( $(date +%s) * 1000 - 1200000 ))" || true)"
if json_field_nonempty "$trace_rsp" "events"; then
  pass "trace returns routed events for request_id"
else
  fail_msg "trace missing events for request_id"
fi

section "G) SSH Guard"
if ./tools/verify-ssh-guard.sh >/dev/null 2>&1; then
  pass "ssh guard verify script passed"
else
  fail_msg "ssh guard verify script failed"
fi

section "H) UI Data Rules"
if ./tools/verify-ui-data.sh >/dev/null 2>&1; then
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
