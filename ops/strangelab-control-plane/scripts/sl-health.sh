#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$REPO_ROOT/tools/_env.sh"

SL_SSH_BIN="${SL_SSH_BIN:-$HOME/.local/bin/sl-ssh}"

if [[ ! -x "$SL_SSH_BIN" ]]; then
  echo "missing sl-ssh at $SL_SSH_BIN"
  exit 1
fi

say() { printf '\n== %s ==\n' "$1"; }

check_http() {
  local name="$1"
  local url="$2"
  if out=$(curl -fsS --max-time 5 "$url" 2>/dev/null); then
    printf '[OK] %s %s\n' "$name" "$url"
    printf '%s\n' "$out"
  else
    printf '[FAIL] %s %s\n' "$name" "$url"
    return 1
  fi
}

check_sl() {
  local host="$1"
  local reqid="$2"
  local cmd="$3"
  shift 3
  if out=$("$SL_SSH_BIN" "$host" "$reqid" "$cmd" "$@" 2>/dev/null); then
    printf '[OK] %s %s\n' "$host" "$cmd"
    printf '%s\n' "$out"
  else
    printf '[FAIL] %s %s\n' "$host" "$cmd"
    return 1
  fi
}

fail=0

say "HTTP health"
check_http token "http://${AUX_HOST}:9123/health" || fail=1
check_http gateway "http://${AUX_HOST}:8099/health" || fail=1
check_http vault "http://${LOGGER_HOST}:8088/health" || fail=1

say "Roving SSH uptime"
check_sl strangelab-pi-aux health-pi-aux-uptime /usr/bin/uptime || fail=1
check_sl strangelab-pi-logger health-pi-logger-uptime /usr/bin/uptime || fail=1
check_sl strangelab-mac-2 health-mac2-uptime /usr/bin/uptime || fail=1

say "Roving SSH disk"
check_sl strangelab-pi-aux health-pi-aux-df /bin/df -h || fail=1
check_sl strangelab-pi-logger health-pi-logger-df /bin/df -h || fail=1
check_sl strangelab-mac-2 health-mac2-df /bin/df -h || fail=1

say "Result"
if [[ "$fail" -eq 0 ]]; then
  echo "LAB HEALTH: OK"
  exit 0
fi

echo "LAB HEALTH: FAIL"
exit 2
