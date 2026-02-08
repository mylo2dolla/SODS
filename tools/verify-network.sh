#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_env.sh"

fail=0

pass() { printf '[PASS] %s\n' "$1"; }
fail_msg() { printf '[FAIL] %s\n' "$1"; fail=1; }

check_cmd() {
  local label="$1"
  shift
  if "$@" >/tmp/sods-verify-last.out 2>/tmp/sods-verify-last.err; then
    pass "$label"
    return 0
  fi
  fail_msg "$label"
  cat /tmp/sods-verify-last.out || true
  cat /tmp/sods-verify-last.err || true
  return 1
}

echo "== A) Network & Host Identity =="

check_cmd "ping pi-aux (${AUX_HOST})" ping -c 1 "$AUX_HOST"
check_cmd "ping pi-logger (${LOGGER_HOST})" ping -c 1 "$LOGGER_HOST"

aux_hostname="$(ssh "$AUX_SSH" 'hostname' 2>/tmp/sods-verify-aux.err || true)"
if [[ "$aux_hostname" == "pi-aux" ]]; then
  pass "pi-aux hostname is pi-aux"
else
  fail_msg "pi-aux hostname mismatch (got: ${aux_hostname:-<empty>})"
  cat /tmp/sods-verify-aux.err || true
fi

logger_hostname="$(ssh "$LOGGER_SSH" 'hostname' 2>/tmp/sods-verify-logger.err || true)"
if [[ "$logger_hostname" == "pi-logger" ]]; then
  pass "pi-logger hostname is pi-logger"
else
  fail_msg "pi-logger hostname mismatch (got: ${logger_hostname:-<empty>})"
  cat /tmp/sods-verify-logger.err || true
fi

if [[ "$fail" -eq 0 ]]; then
  echo "verify-network: PASS"
  exit 0
fi
echo "verify-network: FAIL"
exit 2
