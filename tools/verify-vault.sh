#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_env.sh"
WITH_REBOOT="${WITH_REBOOT:-0}"

VAULT_ADMIN_SSH="${VAULT_ADMIN_SSH:-${VAULT_SSH:-$LOGGER_SSH}}"
VAULT_REMOTE_HOST="${VAULT_REMOTE_HOST:-${VAULT_HOST:-$LOGGER_HOST}}"

fail=0

pass() { printf '[PASS] %s\n' "$1"; }
fail_msg() { printf '[FAIL] %s\n' "$1"; fail=1; }

SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=8
  -o StrictHostKeyChecking=accept-new
)

vault_ssh() {
  local target="$1"
  shift
  ssh "${SSH_OPTS[@]}" "$target" "$@"
}

detect_vault_service() {
  vault_ssh "$VAULT_ADMIN_SSH" 'for s in strangelab-vault strangelab-vault-ingest vault; do systemctl list-unit-files "$s.service" >/dev/null 2>&1 && echo "$s" && exit 0; done; exit 1' 2>/tmp/sods-vault-service.err || return 1
}

echo "== B) Vault (pi-logger) =="

if ! vault_ssh "$VAULT_ADMIN_SSH" 'true' >/dev/null 2>&1; then
  VAULT_ADMIN_SSH="pi@${VAULT_REMOTE_HOST}"
fi
echo "using vault ssh target: $VAULT_ADMIN_SSH"

service="$(detect_vault_service || true)"
if [[ -z "$service" ]]; then
  fail_msg "could not detect vault service (tried: strangelab-vault, strangelab-vault-ingest, vault)"
  cat /tmp/sods-vault-service.err || true
else
  pass "detected vault service: ${service}"
fi

if [[ -n "$service" ]]; then
  if vault_ssh "$VAULT_ADMIN_SSH" "sudo systemctl enable --now ${service} >/dev/null && sudo systemctl is-active ${service}" | grep -q '^active$'; then
    pass "vault service active (${service})"
  else
    fail_msg "vault service failed to start (${service})"
  fi
fi

if vault_ssh "$VAULT_ADMIN_SSH" "sudo ss -lntp | grep -q ':8088\\b'"; then
  pass "vault listens on :8088"
else
  fail_msg "vault not listening on :8088"
fi

if vault_ssh "$VAULT_ADMIN_SSH" "curl -fsS -X POST http://localhost:8088/v1/ingest -H 'content-type: application/json' -d '{\"type\":\"vault.test\",\"src\":\"pi-logger\",\"ts_ms\":0,\"data\":{\"ok\":true}}' >/dev/null"; then
  pass "local ingest POST works"
else
  fail_msg "local ingest POST failed"
fi

if curl -fsS -X POST "http://${VAULT_REMOTE_HOST}:8088/v1/ingest" \
  -H 'content-type: application/json' \
  -d '{"type":"vault.test","src":"mac1","ts_ms":0,"data":{"ok":true}}' >/dev/null; then
  pass "remote ingest POST works"
else
  fail_msg "remote ingest POST failed"
fi

if [[ "$WITH_REBOOT" == "1" && -n "$service" ]]; then
  echo "Running reboot persistence check..."
  if vault_ssh "$VAULT_ADMIN_SSH" 'sudo reboot' >/dev/null 2>&1; then
    pass "reboot issued"
  else
    fail_msg "failed to issue reboot"
  fi
  sleep 10
  recovered=0
  for _ in $(seq 1 60); do
    if vault_ssh "$VAULT_ADMIN_SSH" "sudo systemctl is-active ${service}" 2>/dev/null | grep -q '^active$'; then
      recovered=1
      break
    fi
    sleep 2
  done
  if [[ "$recovered" -eq 1 ]]; then
    pass "vault service recovered after reboot (${service})"
  else
    fail_msg "vault service did not recover after reboot"
  fi
fi

if [[ "$fail" -eq 0 ]]; then
  echo "verify-vault: PASS"
  exit 0
fi
echo "verify-vault: FAIL"
exit 2
