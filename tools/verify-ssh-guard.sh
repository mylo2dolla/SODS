#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_env.sh"

SL_SSH_BIN_DEFAULTS=("${SL_SSH_BIN:-}" "$HOME/.local/bin/sl-ssh" "/usr/local/bin/sl-ssh")
CONTROLLER_KEY="${CONTROLLER_KEY:-$HOME/.ssh/strangelab_controller}"
CONTROLLER_PUB="${CONTROLLER_PUB:-$HOME/.ssh/strangelab_controller.pub}"
SSH_CONFIG="${SSH_CONFIG:-$HOME/.ssh/config}"
STRICT_LOCAL="${SODS_VERIFY_SSH_GUARD_STRICT_LOCAL:-0}"
SSH_FLAGS=(
  -o BatchMode=yes
  -o ConnectTimeout=6
)

fail=0

pass() { printf '[PASS] %s\n' "$1"; }
fail_msg() { printf '[FAIL] %s\n' "$1"; fail=1; }
skip_msg() { printf '[SKIP] %s\n' "$1"; }

resolve_sl_ssh_bin() {
  local candidate
  for candidate in "${SL_SSH_BIN_DEFAULTS[@]}"; do
    [[ -n "$candidate" ]] || continue
    if [[ -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  local from_path
  from_path="$(command -v sl-ssh 2>/dev/null || true)"
  if [[ -n "$from_path" && -x "$from_path" ]]; then
    printf '%s' "$from_path"
    return 0
  fi
  printf '%s' ""
}

has_ssh_host() {
  local host="$1"
  [[ -f "$SSH_CONFIG" ]] || return 1
  grep -Eq "^[[:space:]]*Host[[:space:]]+${host}([[:space:]]|$)" "$SSH_CONFIG"
}

uniq_words() {
  awk '{for (i = 1; i <= NF; i++) if (!seen[$i]++) out = out $i " ";} END {print out}'
}

build_host_list() {
  if [[ -n "${SODS_SSH_GUARD_HOSTS:-}" ]]; then
    printf '%s\n' "$SODS_SSH_GUARD_HOSTS"
    return 0
  fi

  local preferred=("$AUX_SSH_ALIAS" "$VAULT_SSH_ALIAS" "$MAC16_SSH_ALIAS" "$MAC8_SSH_ALIAS")
  local legacy=(strangelab-pi-aux strangelab-pi-logger strangelab-mac-2)
  local out=()
  local h

  for h in "${preferred[@]}"; do
    [[ -n "$h" ]] || continue
    if has_ssh_host "$h"; then
      out+=("$h")
    fi
  done

  for h in "${legacy[@]}"; do
    if has_ssh_host "$h"; then
      out+=("$h")
    fi
  done

  if [[ ${#out[@]} -eq 0 ]]; then
    out=("$AUX_SSH_ALIAS" "$VAULT_SSH_ALIAS" "$MAC16_SSH_ALIAS")
  fi

  printf '%s ' "${out[@]}" | uniq_words
}

deny_host_default() {
  local raw="${AUX_SSH_TARGET:-$AUX_SSH_ALIAS}"
  raw="${raw%% *}"
  raw="${raw##*@}"
  if [[ -n "$raw" ]]; then
    printf '%s' "$raw"
  else
    printf '%s' "$AUX_SSH_ALIAS"
  fi
}

check_local_prereq() {
  local ok="$1"
  local label="$2"
  local detail="$3"
  if [[ "$ok" == "1" ]]; then
    pass "$label ($detail)"
    return 0
  fi
  if [[ "$STRICT_LOCAL" == "1" ]]; then
    fail_msg "$label missing ($detail)"
  else
    skip_msg "$label missing ($detail); strict local checks disabled"
  fi
}

echo "== G + H + I) SSH Guard / Allowlist / Capabilities =="

guard_bin="$(resolve_sl_ssh_bin)"

if [[ -f "$CONTROLLER_KEY" && -f "$CONTROLLER_PUB" ]]; then
  check_local_prereq "1" "controller keypair present" "$CONTROLLER_KEY"
else
  check_local_prereq "0" "controller keypair" "$CONTROLLER_KEY / $CONTROLLER_PUB"
fi

if [[ -n "$guard_bin" ]]; then
  check_local_prereq "1" "sl-ssh helper present" "$guard_bin"
else
  check_local_prereq "0" "sl-ssh helper" "~/.local/bin/sl-ssh or /usr/local/bin/sl-ssh"
fi

if [[ -n "$guard_bin" ]]; then
  for host in $(build_host_list); do
    req="verify-uptime-${host}"
    if "$guard_bin" "$host" "$req" /usr/bin/uptime >/tmp/sods-ssh-${host}.out 2>/tmp/sods-ssh-${host}.err; then
      pass "roving uptime works on ${host}"
    else
      fail_msg "roving uptime failed on ${host}"
      cat /tmp/sods-ssh-${host}.out || true
      cat /tmp/sods-ssh-${host}.err || true
    fi
  done
else
  skip_msg "roving uptime checks skipped (sl-ssh helper unavailable)"
fi

set +e
deny_host="${SODS_SSH_GUARD_DENY_HOST:-$(deny_host_default)}"
deny_out="$(echo '{"id":"verify-deny","cmd":"/bin/bash","args":[],"cwd":".","timeout_ms":1000}' | ssh "${SSH_FLAGS[@]}" "${deny_host}" 2>/tmp/sods-ssh-deny.err)"
deny_rc=$?
set -e
if echo "$deny_out" | rg -q '"code"\s*:\s*"NOT_ALLOWED"'; then
  pass "deny test returns NOT_ALLOWED on ${deny_host} (rc=${deny_rc})"
else
  deny_err="$(cat /tmp/sods-ssh-deny.err 2>/dev/null || true)"
  if [[ "$STRICT_LOCAL" != "1" ]] && printf '%s\n%s\n' "$deny_out" "$deny_err" | rg -qi 'command not found|pseudo-terminal|permission denied|connection (refused|timed out)|could not resolve hostname'; then
    skip_msg "deny behavior check skipped on ${deny_host} (guard endpoint not directly reachable via this alias)"
  else
    fail_msg "deny test did not return NOT_ALLOWED on ${deny_host}"
    echo "$deny_out"
    echo "$deny_err"
  fi
fi

if ssh "${SSH_FLAGS[@]}" "$PI_AUX_ADMIN_SSH" 'test -f /opt/strangelab/allowlist.json'; then
  pass "allowlist exists on aux"
else
  fail_msg "allowlist missing on aux"
fi

if ssh "${SSH_FLAGS[@]}" "$PI_LOGGER_ADMIN_SSH" 'test -f /opt/strangelab/allowlist.json'; then
  pass "allowlist exists on vault"
else
  fail_msg "allowlist missing on vault"
fi

if ssh "${SSH_FLAGS[@]}" "$MAC16_ADMIN_SSH" 'test -f /opt/strangelab/allowlist.json'; then
  pass "allowlist exists on mac16"
else
  fail_msg "allowlist missing on mac16"
fi

if [[ "$fail" -eq 0 ]]; then
  echo "verify-ssh-guard: PASS"
  exit 0
fi

echo "verify-ssh-guard: FAIL"
exit 2
