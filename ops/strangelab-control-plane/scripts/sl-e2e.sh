#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$REPO_ROOT/tools/_env.sh"

SL_SSH_BIN="${SL_SSH_BIN:-$HOME/.local/bin/sl-ssh}"
VAULT_HOST="${VAULT_HOST:-$LOGGER_HOST}"
VAULT_SVC="${VAULT_SVC:-strangelab-vault-ingest}"

fail=0
stopped_vault=0

say() { printf "\n== %s ==\n" "$1"; }
ok() { printf "[OK] %s\n" "$1"; }
bad() { printf "[FAIL] %s\n" "$1"; fail=1; }

run_cmd() {
  local label="$1"
  shift
  if "$@" >/tmp/sl-e2e-last.out 2>/tmp/sl-e2e-last.err; then
    ok "$label"
    cat /tmp/sl-e2e-last.out
    return 0
  fi
  bad "$label"
  cat /tmp/sl-e2e-last.out || true
  cat /tmp/sl-e2e-last.err || true
  return 1
}

cleanup() {
  if [[ "$stopped_vault" -eq 1 ]]; then
    ssh "pi@${VAULT_HOST}" "sudo systemctl start ${VAULT_SVC}" >/dev/null 2>&1 || true
    stopped_vault=0
  fi
}
trap cleanup EXIT

if [[ ! -x "$SL_SSH_BIN" ]]; then
  echo "missing sl-ssh at $SL_SSH_BIN"
  exit 1
fi

say "Preflight"
run_cmd "ping pi-aux" ping -c 1 "$AUX_HOST" || true
run_cmd "ping pi-logger" ping -c 1 "$VAULT_HOST" || true

say "Core HTTP Health"
run_cmd "token health" curl -fsS "http://${AUX_HOST}:9123/health" || true
run_cmd "gateway health" curl -fsS "http://${AUX_HOST}:8099/health" || true
run_cmd "vault health" curl -fsS "http://${VAULT_HOST}:8088/health" || true

say "Vault Ingest Local + Remote"
run_cmd "vault local ingest ts_ms=0" ssh "pi@${VAULT_HOST}" \
  "curl -fsS -X POST http://localhost:8088/v1/ingest -H 'content-type: application/json' -d '{\"type\":\"vault.test\",\"src\":\"pi-logger\",\"ts_ms\":0,\"data\":{\"ok\":true}}'" || true
run_cmd "vault remote ingest ts_ms=0" curl -fsS -X POST "http://${VAULT_HOST}:8088/v1/ingest" \
  -H "content-type: application/json" \
  -d '{"type":"vault.test","src":"mac1","ts_ms":0,"data":{"ok":true}}' || true

say "Token + God Gateway"
run_cmd "token issue" curl -fsS -X POST "http://${AUX_HOST}:9123/token" \
  -H "content-type: application/json" \
  -d '{"identity":"sl-e2e","room":"strangelab"}' || true
run_cmd "god whoami" curl -fsS -X POST "http://${AUX_HOST}:8099/god" \
  -H "content-type: application/json" \
  -d '{"op":"whoami"}' || true

say "Roving Guard"
run_cmd "roving uptime pi-aux" "$SL_SSH_BIN" strangelab-pi-aux e2e-up-aux /usr/bin/uptime || true
run_cmd "roving uptime pi-logger" "$SL_SSH_BIN" strangelab-pi-logger e2e-up-log /usr/bin/uptime || true
run_cmd "roving uptime mac2" "$SL_SSH_BIN" strangelab-mac-2 e2e-up-m2 /usr/bin/uptime || true

set +e
deny_out="$(echo '{"id":"e2e-deny","cmd":"/bin/bash","args":[],"cwd":".","timeout_ms":1000}' | ssh strangelab-pi-aux 2>/tmp/sl-e2e-deny.err)"
deny_rc=$?
set -e
if echo "$deny_out" | grep -q '"code": "NOT_ALLOWED"\|"code":"NOT_ALLOWED"'; then
  ok "allowlist deny returns NOT_ALLOWED (rc=$deny_rc)"
  echo "$deny_out"
else
  bad "allowlist deny mismatch"
  echo "$deny_out"
  cat /tmp/sl-e2e-deny.err || true
fi

say "Fail-Closed Vault Test"
if ssh "pi@${VAULT_HOST}" "sudo systemctl stop ${VAULT_SVC}" >/tmp/sl-e2e-stop.out 2>/tmp/sl-e2e-stop.err; then
  stopped_vault=1
  ok "vault stopped"
else
  bad "vault stop failed"
  cat /tmp/sl-e2e-stop.err || true
fi

fc_resp="$(curl -sS -w '\nHTTP:%{http_code}\n' -X POST "http://${AUX_HOST}:8099/god" -H 'content-type: application/json' -d '{"op":"whoami"}' || true)"
echo "$fc_resp"
if echo "$fc_resp" | grep -q 'HTTP:500'; then
  ok "fail-closed returned HTTP 500 while vault down"
else
  bad "fail-closed did not return HTTP 500"
fi

if ssh "pi@${VAULT_HOST}" "sudo systemctl start ${VAULT_SVC}" >/tmp/sl-e2e-start.out 2>/tmp/sl-e2e-start.err; then
  stopped_vault=0
  ok "vault restarted"
else
  bad "vault restart failed"
  cat /tmp/sl-e2e-start.err || true
fi

sleep 2
run_cmd "vault health after restart" curl -fsS "http://${VAULT_HOST}:8088/health" || true
run_cmd "god whoami after restart" curl -fsS -X POST "http://${AUX_HOST}:8099/god" \
  -H "content-type: application/json" \
  -d '{"op":"whoami"}' || true

say "Result"
if [[ "$fail" -eq 0 ]]; then
  echo "SL-E2E: PASS"
  exit 0
fi
echo "SL-E2E: FAIL"
exit 2
