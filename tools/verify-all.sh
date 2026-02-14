#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_env.sh"

fail=0

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

section "H) UI Data Rules"
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
