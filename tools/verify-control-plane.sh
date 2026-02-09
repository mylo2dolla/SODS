#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_env.sh"

fail=0

pass() { printf '[PASS] %s\n' "$1"; }
fail_msg() { printf '[FAIL] %s\n' "$1"; fail=1; }

check_remote_active() {
  local host="$1"
  local svc="$2"
  ssh "$host" "sudo systemctl is-active '$svc' 2>/dev/null || true"
}

echo "== C + D + F) Control Plane / Agents / God Path =="

if ssh "$AUX_SSH_TARGET" "sudo docker ps --format '{{.Names}}' | grep -qi livekit"; then
  pass "LiveKit container running"
else
  fail_msg "LiveKit container not running"
fi

if ssh "$AUX_SSH_TARGET" "sudo ss -lntp | grep -q ':7880\\b'"; then
  pass "LiveKit listens on :7880"
else
  fail_msg "LiveKit not listening on :7880"
fi

for svc in strangelab-token strangelab-god-gateway; do
  status="$(check_remote_active "$AUX_SSH_TARGET" "$svc")"
  if [[ "$status" == "active" ]]; then
    pass "${svc} active"
  else
    fail_msg "${svc} inactive (${status:-unknown})"
  fi
done

ops_feed_status="$(check_remote_active "$AUX_SSH_TARGET" "strangelab-ops-feed")"
if [[ "$ops_feed_status" == "active" ]]; then
  pass "strangelab-ops-feed active"
else
  fail_msg "strangelab-ops-feed inactive (${ops_feed_status:-unknown})"
fi

if curl -fsS -X POST "$TOKEN_URL" \
  -H 'content-type: application/json' \
  -d '{"identity":"verify-control-plane","room":"strangelab"}' | rg -q '"token"'; then
  pass "token endpoint returns token"
else
  fail_msg "token endpoint failed"
fi

if curl -fsS "${OPS_FEED_URL}/health" | rg -q '"ok"[[:space:]]*:[[:space:]]*true'; then
  pass "ops-feed health endpoint OK"
else
  fail_msg "ops-feed health endpoint failed"
fi

request_id="verify-snapshot-now-$(date +%s)"
if curl -fsS -X POST "$GOD_URL" \
  -H 'content-type: application/json' \
  -d "{\"action\":\"snapshot.now\",\"scope\":\"tier1\",\"target\":null,\"request_id\":\"${request_id}\",\"reason\":\"verify-control-plane\",\"ts_ms\":0,\"args\":{\"dry_run\":true}}" | rg -q '"ok"'; then
  pass "god gateway accepts structured action"
else
  fail_msg "god gateway structured action failed"
fi

aux_exec_status="$(check_remote_active "$AUX_SSH_TARGET" "strangelab-exec-agent@pi-aux")"
if [[ "$aux_exec_status" == "active" ]]; then
  pass "exec-agent active on pi-aux"
else
  fallback="$(check_remote_active "$AUX_SSH_TARGET" "strangelab-exec-agent")"
  if [[ "$fallback" == "active" ]]; then
    pass "exec-agent active on pi-aux (fallback unit name)"
  else
    fail_msg "exec-agent inactive on pi-aux"
  fi
fi

log_exec_status="$(check_remote_active "$VAULT_SSH_TARGET" "strangelab-exec-agent@pi-logger")"
if [[ "$log_exec_status" == "active" ]]; then
  pass "exec-agent active on pi-logger"
else
  fallback="$(check_remote_active "$VAULT_SSH_TARGET" "strangelab-exec-agent")"
  if [[ "$fallback" == "active" ]]; then
    pass "exec-agent active on pi-logger (fallback unit name)"
  else
    fail_msg "exec-agent inactive on pi-logger"
  fi
fi

if launchctl print "system/com.strangelab.exec-agent.mac1" >/dev/null 2>&1 || launchctl print "system/com.strangelab.exec-agent.mac2" >/dev/null 2>&1; then
  pass "launchd exec-agent present on this mac (mac1 or mac2)"
else
  if ssh -o BatchMode=yes "$MAC2_SSH" "launchctl print system/com.strangelab.exec-agent.mac2 >/dev/null 2>&1"; then
    pass "launchd exec-agent present on remote mac2"
  else
    fail_msg "launchd exec-agent not found locally or on mac2"
  fi
fi

if [[ "$fail" -eq 0 ]]; then
  echo "verify-control-plane: PASS"
  exit 0
fi
echo "verify-control-plane: FAIL"
exit 2
