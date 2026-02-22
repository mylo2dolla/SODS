#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_env.sh"

fail=0

pass() { printf '[PASS] %s\n' "$1"; }
fail_msg() { printf '[FAIL] %s\n' "$1"; fail=1; }

SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=accept-new
)

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

resolve_ipv4() {
  local host="$1"
  python3 - "$host" <<'PY'
import socket
import sys
host = sys.argv[1]
try:
    print(socket.gethostbyname(host))
except Exception:
    print("")
PY
}

check_ping_pair() {
  local label="$1"
  local configured_host="$2"
  local resolved_ip="$3"

  check_cmd "ping ${label} configured (${configured_host})" ping -c 1 "$configured_host"

  if [[ -z "$resolved_ip" ]]; then
    fail_msg "resolve ${label} failed (${configured_host})"
    return 1
  fi

  if [[ "$resolved_ip" == "$configured_host" ]]; then
    pass "resolve ${label} (${configured_host} -> ${resolved_ip})"
    return 0
  fi

  check_cmd "ping ${label} resolved-ip (${resolved_ip} via ${configured_host})" ping -c 1 "$resolved_ip"
}

echo "== A) Network & Host Identity =="

aux_resolved_ip="$(resolve_ipv4 "$AUX_HOST")"
logger_resolved_ip="$(resolve_ipv4 "$LOGGER_HOST")"

check_ping_pair "pi-aux" "$AUX_HOST" "$aux_resolved_ip"
check_ping_pair "pi-logger" "$LOGGER_HOST" "$logger_resolved_ip"

aux_target_used="$AUX_SSH_TARGET"
aux_hostname="$(ssh "${SSH_OPTS[@]}" "$aux_target_used" 'hostname' 2>/tmp/sods-verify-aux.err || true)"
if [[ -z "$aux_hostname" ]]; then
  aux_target_used="pi@${AUX_HOST}"
  aux_hostname="$(ssh "${SSH_OPTS[@]}" "$aux_target_used" 'hostname' 2>/tmp/sods-verify-aux.err || true)"
fi
if [[ "$aux_hostname" == "pi-aux" ]]; then
  pass "pi-aux hostname is pi-aux (ssh target: ${aux_target_used})"
else
  fail_msg "pi-aux hostname mismatch via ${aux_target_used} (got: ${aux_hostname:-<empty>})"
  cat /tmp/sods-verify-aux.err || true
fi

logger_target_used="$VAULT_SSH_TARGET"
logger_hostname="$(ssh "${SSH_OPTS[@]}" "$logger_target_used" 'hostname' 2>/tmp/sods-verify-logger.err || true)"
if [[ -z "$logger_hostname" ]]; then
  logger_target_used="pi@${LOGGER_HOST}"
  logger_hostname="$(ssh "${SSH_OPTS[@]}" "$logger_target_used" 'hostname' 2>/tmp/sods-verify-logger.err || true)"
fi
if [[ "$logger_hostname" == "pi-logger" ]]; then
  pass "pi-logger hostname is pi-logger (ssh target: ${logger_target_used})"
else
  fail_msg "pi-logger hostname mismatch via ${logger_target_used} (got: ${logger_hostname:-<empty>})"
  cat /tmp/sods-verify-logger.err || true
fi

if [[ "$fail" -eq 0 ]]; then
  echo "verify-network: PASS"
  exit 0
fi
echo "verify-network: FAIL"
exit 2
