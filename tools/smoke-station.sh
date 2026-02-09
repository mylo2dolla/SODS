#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/tools/_env.sh"

PI_LOGGER_URL="${PI_LOGGER_URL:-http://127.0.0.1:1}"

ok() { printf "ok: %s\n" "$*"; }
fail() { printf "FAIL: %s\n" "$*" >&2; exit 1; }

pick_free_port() {
  local p
  for p in 9124 9125 9126 9127 9128 9129 9130 9131 9132 9133 9134; do
    if ! lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

SODS_PORT="${SODS_SMOKE_PORT:-$(pick_free_port || true)}"
if [[ -z "${SODS_PORT:-}" ]]; then
  fail "no free port found in 9124-9134 (set SODS_SMOKE_PORT=...)"
fi
SODS_BASE_URL="http://127.0.0.1:${SODS_PORT}"

station_ok() {
  curl -fsS --max-time 2 "${SODS_BASE_URL%/}/api/status" >/dev/null 2>&1
}

wait_station() {
  local max_s="${1:-10}"
  local start
  start="$(date +%s)"
  while true; do
    if station_ok; then
      return 0
    fi
    local now
    now="$(date +%s)"
    if (( now - start >= max_s )); then
      return 1
    fi
    sleep 0.4
  done
}

if ! station_ok; then
  if [[ ! -x "$REPO_ROOT/tools/sods" ]]; then
    fail "missing executable: $REPO_ROOT/tools/sods"
  fi
  :
fi

ok "starting isolated station (port=$SODS_PORT)"
nohup "$REPO_ROOT/tools/sods" start --pi-logger "$PI_LOGGER_URL" --port "$SODS_PORT" >/dev/null 2>&1 &
STATION_PID="$!"

cleanup() {
  if kill -0 "$STATION_PID" >/dev/null 2>&1; then
    kill "$STATION_PID" >/dev/null 2>&1 || true
    wait "$STATION_PID" >/dev/null 2>&1 || true
    sleep 0.4
    kill -9 "$STATION_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if ! wait_station 14; then
  fail "station did not become ready at ${SODS_BASE_URL%/}"
fi
ok "station ready: ${SODS_BASE_URL%/}"

check_get() {
  local path="$1"
  local url="${SODS_BASE_URL%/}${path}"
  local out
  out="$(curl -fsS --max-time 4 "$url" || true)"
  if [[ -z "$out" ]]; then
    fail "GET $path returned empty body"
  fi
  ok "GET $path"
}

check_get "/api/status"
check_get "/api/nodes"
check_get "/api/flash"
check_get "/api/registry/nodes"
check_get "/health"

ok "smoke pass"
