#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_env.sh"

fail=0

pass() { printf '[PASS] %s\n' "$1"; }
fail_msg() { printf '[FAIL] %s\n' "$1"; fail=1; }

SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=8
  -o StrictHostKeyChecking=accept-new
)

ssh_exec() {
  local target="$1"
  shift
  ssh "${SSH_OPTS[@]}" "$target" "$@"
}

resolve_ssh_target() {
  local preferred="$1"
  local fallback="$2"
  if ssh_exec "$preferred" 'true' >/dev/null 2>&1; then
    printf '%s' "$preferred"
    return 0
  fi
  printf '%s' "$fallback"
}

check_remote_active() {
  local host="$1"
  local svc="$2"
  ssh_exec "$host" "sudo systemctl is-active '$svc' 2>/dev/null || true" || true
}

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

echo "== C + D + F) Control Plane / Federation Path =="

AUX_RUNTIME_SSH_TARGET="$(resolve_ssh_target "${AUX_SSH_TARGET:-pi@${AUX_HOST}}" "pi@${AUX_HOST}")"
VAULT_RUNTIME_SSH_TARGET="$(resolve_ssh_target "${VAULT_SSH_TARGET:-pi@${LOGGER_HOST}}" "pi@${LOGGER_HOST}")"
echo "using aux ssh target: $AUX_RUNTIME_SSH_TARGET"
echo "using vault ssh target: $VAULT_RUNTIME_SSH_TARGET"

for svc in strangelab-codegatchi-tunnel strangelab-token strangelab-god-gateway strangelab-ops-feed; do
  status="$(check_remote_active "$AUX_RUNTIME_SSH_TARGET" "$svc")"
  if [[ "$status" == "active" ]]; then
    pass "${svc} active on aux"
  else
    fail_msg "${svc} inactive on aux (${status:-unknown})"
  fi
done

vault_status="$(check_remote_active "$VAULT_RUNTIME_SSH_TARGET" "strangelab-vault-ingest")"
if [[ "$vault_status" == "active" ]]; then
  pass "strangelab-vault-ingest active on vault"
else
  fail_msg "strangelab-vault-ingest inactive on vault (${vault_status:-unknown})"
fi

if "$SCRIPT_DIR/verify-federation-contract.sh" >/dev/null 2>&1; then
  pass "federation action contract validates"
else
  fail_msg "federation action contract validation failed"
fi

tunnel_code="$(ssh_exec "$AUX_RUNTIME_SSH_TARGET" "curl -sS -o /dev/null -w '%{http_code}' --max-time 8 '${FED_GATEWAY_HEALTH_URL}'" 2>/dev/null || true)"
if [[ "$tunnel_code" == "401" ]]; then
  pass "codegatchi gateway reachable from aux tunnel (${FED_GATEWAY_HEALTH_URL}, auth required)"
elif [[ "$tunnel_code" == "200" ]]; then
  tunnel_rsp="$(ssh_exec "$AUX_RUNTIME_SSH_TARGET" "curl -fsS --max-time 8 '${FED_GATEWAY_HEALTH_URL}'" 2>/dev/null || true)"
  if json_has_ok_true "$tunnel_rsp"; then
    pass "codegatchi gateway reachable from aux tunnel (${FED_GATEWAY_HEALTH_URL})"
  else
    fail_msg "codegatchi gateway health response invalid from aux tunnel"
  fi
else
  fail_msg "codegatchi gateway unreachable from aux tunnel (http=${tunnel_code:-none})"
fi

token_health_rsp="$(curl --max-time 8 -fsS "$TOKEN_HEALTH_URL" 2>/dev/null || true)"
if json_has_ok_true "$token_health_rsp"; then
  pass "token health endpoint OK"
else
  fail_msg "token health endpoint failed (${TOKEN_HEALTH_URL})"
fi

god_health_rsp="$(curl --max-time 8 -fsS "$GOD_HEALTH_URL" 2>/dev/null || true)"
if json_has_ok_true "$god_health_rsp"; then
  pass "god gateway health endpoint OK"
else
  fail_msg "god gateway health endpoint failed (${GOD_HEALTH_URL})"
fi

ops_health_rsp="$(curl --max-time 8 -fsS "$OPS_FEED_HEALTH_URL" 2>/dev/null || true)"
if json_has_ok_true "$ops_health_rsp"; then
  pass "ops-feed health endpoint OK"
else
  fail_msg "ops-feed health endpoint failed (${OPS_FEED_HEALTH_URL})"
fi

vault_health_rsp="$(curl --max-time 8 -fsS "$VAULT_HEALTH_URL" 2>/dev/null || true)"
if json_has_ok_true "$vault_health_rsp"; then
  pass "vault health endpoint OK"
else
  fail_msg "vault health endpoint failed (${VAULT_HEALTH_URL})"
fi

token_rsp="$(curl --max-time 8 -fsS -X POST "$TOKEN_URL" -H 'content-type: application/json' -d '{"identity":"verify-control-plane","room":"strangelab"}' 2>/dev/null || true)"
if printf '%s' "$token_rsp" | rg -q '"token"\s*:\s*"[^"]+'; then
  pass "token endpoint returns compatibility token"
else
  fail_msg "token endpoint failed to return token"
fi

request_id="verify-snapshot-now-$(date +%s)-$RANDOM"
god_rsp="$(curl --max-time 8 -sS -X POST "$GOD_URL" -H 'content-type: application/json' -d "{\"action\":\"snapshot.now\",\"scope\":\"tier1\",\"target\":null,\"request_id\":\"${request_id}\",\"reason\":\"verify-control-plane\",\"ts_ms\":0,\"args\":{\"dry_run\":true}}" || true)"
if json_has_ok_true "$god_rsp"; then
  pass "god gateway accepts structured action"
else
  fail_msg "god gateway structured action failed"
fi

trace_rsp="$(curl --max-time 8 -fsS "${OPS_FEED_URL}/trace?request_id=${request_id}&limit=80&scan_limit=220&since_ms=$(( $(date +%s) * 1000 - 1200000 ))" 2>/dev/null || true)"
if printf '%s' "$trace_rsp" | rg -q 'control\.god_button\.(intent|result)'; then
  pass "ops-feed trace returns god-button evidence"
else
  fail_msg "ops-feed trace missing god-button evidence"
fi

if [[ "$fail" -eq 0 ]]; then
  echo "verify-control-plane: PASS"
  exit 0
fi

echo "verify-control-plane: FAIL"
exit 2
