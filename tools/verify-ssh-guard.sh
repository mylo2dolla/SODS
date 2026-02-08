#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_env.sh"

SL_SSH_BIN="${SL_SSH_BIN:-$HOME/.local/bin/sl-ssh}"
CONTROLLER_KEY="${CONTROLLER_KEY:-$HOME/.ssh/strangelab_controller}"
CONTROLLER_PUB="${CONTROLLER_PUB:-$HOME/.ssh/strangelab_controller.pub}"
SSH_FLAGS=(
  -o BatchMode=yes
  -o ConnectTimeout=6
)

fail=0

pass() { printf '[PASS] %s\n' "$1"; }
fail_msg() { printf '[FAIL] %s\n' "$1"; fail=1; }

echo "== G + H + I) SSH Guard / Allowlist / Capabilities =="

if [[ -f "$CONTROLLER_KEY" && -f "$CONTROLLER_PUB" ]]; then
  pass "controller keypair present"
else
  fail_msg "controller keypair missing ($CONTROLLER_KEY / $CONTROLLER_PUB)"
fi

if [[ -x "$SL_SSH_BIN" ]]; then
  pass "sl-ssh helper present ($SL_SSH_BIN)"
else
  fail_msg "sl-ssh helper missing ($SL_SSH_BIN)"
fi

if [[ -x "$SL_SSH_BIN" ]]; then
  for host in strangelab-pi-aux strangelab-pi-logger strangelab-mac-2; do
    req="verify-uptime-${host}"
    if "$SL_SSH_BIN" "$host" "$req" /usr/bin/uptime >/tmp/sods-ssh-${host}.out 2>/tmp/sods-ssh-${host}.err; then
      pass "roving uptime works on ${host}"
    else
      fail_msg "roving uptime failed on ${host}"
      cat /tmp/sods-ssh-${host}.out || true
      cat /tmp/sods-ssh-${host}.err || true
    fi
  done
fi

set +e
deny_out="$(echo '{"id":"verify-deny","cmd":"/bin/bash","args":[],"cwd":".","timeout_ms":1000}' | ssh "${SSH_FLAGS[@]}" strangelab-pi-aux 2>/tmp/sods-ssh-deny.err)"
deny_rc=$?
set -e
if echo "$deny_out" | rg -q '"code"\s*:\s*"NOT_ALLOWED"'; then
  pass "deny test returns NOT_ALLOWED (rc=${deny_rc})"
else
  fail_msg "deny test did not return NOT_ALLOWED"
  echo "$deny_out"
  cat /tmp/sods-ssh-deny.err || true
fi

if ssh "${SSH_FLAGS[@]}" "$PI_AUX_ADMIN_SSH" 'test -f /opt/strangelab/allowlist.json'; then
  pass "allowlist exists on pi-aux"
else
  fail_msg "allowlist missing on pi-aux"
fi

if ssh "${SSH_FLAGS[@]}" "$PI_LOGGER_ADMIN_SSH" 'test -f /opt/strangelab/allowlist.json'; then
  pass "allowlist exists on pi-logger"
else
  fail_msg "allowlist missing on pi-logger"
fi

if ssh "${SSH_FLAGS[@]}" "$MAC2_ADMIN_SSH" 'test -f /opt/strangelab/allowlist.json'; then
  pass "allowlist exists on mac2"
else
  fail_msg "allowlist missing on mac2"
fi

if [[ "$fail" -eq 0 ]]; then
  echo "verify-ssh-guard: PASS"
  exit 0
fi
echo "verify-ssh-guard: FAIL"
exit 2
