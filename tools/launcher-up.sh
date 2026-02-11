#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LOG_DIR="$HOME/Library/Logs/SODS"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/launcher.log"

source "$REPO_ROOT/tools/_env.sh"

SODS_PORT="${SODS_PORT:-9123}"
SODS_BASE_URL="${SODS_BASE_URL:-${SODS_STATION_URL:-http://127.0.0.1:${SODS_PORT}}}"
LOCAL_READY_URL="http://127.0.0.1:${SODS_PORT}"
CONTROL_PLANE_UP_SCRIPT="$REPO_ROOT/tools/control-plane-up.sh"
CONTROL_PLANE_STATUS_SCRIPT="$REPO_ROOT/tools/control-plane-status.sh"
CONTROL_PLANE_TIMEOUT_S="${CONTROL_PLANE_TIMEOUT_S:-20}"

APP_PATH="${DEVSTATION_APP_PATH:-$REPO_ROOT/dist/DevStation.app}"
START_VIEW="${DEVSTATION_START_VIEW:-dashboard}"
ROUNDUP_MODE="${DEVSTATION_ROUNDUP_MODE:-connect-identify}"

exec >>"$LOG_FILE" 2>&1
echo "=== launcher-up $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
echo "repo=$REPO_ROOT"
echo "station=$SODS_BASE_URL"
echo "port=$SODS_PORT"

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
    # If the station is local, accept readiness via loopback even if SODS_BASE_URL is LAN IP.
    if [[ "$SODS_BASE_URL" == *"localhost"* || "$SODS_BASE_URL" == *"127.0.0.1"* || "$SODS_BASE_URL" == *"${MAC2_HOST:-__}"* ]]; then
      if curl -fsS --max-time 2 "${LOCAL_READY_URL%/}/api/status" >/dev/null 2>&1; then
        return 0
      fi
    fi
    local now
    now="$(date +%s)"
    if (( now - start >= max_s )); then
      return 1
    fi
    sleep 0.4
  done
}

run_with_timeout() {
  local timeout_s="$1"
  shift
  "$@" &
  local cmd_pid=$!
  local start_ts
  start_ts="$(date +%s)"
  while kill -0 "$cmd_pid" >/dev/null 2>&1; do
    local now_ts
    now_ts="$(date +%s)"
    if (( now_ts - start_ts >= timeout_s )); then
      kill -TERM "$cmd_pid" >/dev/null 2>&1 || true
      sleep 1
      kill -KILL "$cmd_pid" >/dev/null 2>&1 || true
      wait "$cmd_pid" >/dev/null 2>&1 || true
      return 124
    fi
    sleep 1
  done
  wait "$cmd_pid"
}

run_control_plane_bootstrap() {
  if [[ ! -x "$CONTROL_PLANE_UP_SCRIPT" ]]; then
    echo "WARN control-plane bootstrap script missing: $CONTROL_PLANE_UP_SCRIPT"
    return 1
  fi
  echo "running full-fleet auto-heal (timeout=${CONTROL_PLANE_TIMEOUT_S}s)..."
  local rc=0
  run_with_timeout "$CONTROL_PLANE_TIMEOUT_S" "$CONTROL_PLANE_UP_SCRIPT" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    echo "control-plane-up completed"
    return 0
  fi
  if [[ "$rc" -eq 124 ]]; then
    echo "WARN control-plane-up timed out after ${CONTROL_PLANE_TIMEOUT_S}s"
  else
    echo "WARN control-plane-up exited with code $rc"
  fi
  return "$rc"
}

if ! station_ok; then
  echo "station not responding; starting via tools/station..."
  "$REPO_ROOT/tools/station" start || true
fi

if ! wait_station 10; then
  echo "ERROR: station failed to start at ${SODS_BASE_URL%/} (see $LOG_DIR/station.log)"
  /usr/bin/osascript -e 'display notification "Station failed to start. Check ~/Library/Logs/SODS/launcher.log" with title "SODS Launcher"' || true
  exit 2
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Dev Station app missing at $APP_PATH; building..."
  "$REPO_ROOT/tools/devstation-build.sh"
fi

run_control_plane_bootstrap || true
if [[ -x "$CONTROL_PLANE_STATUS_SCRIPT" ]]; then
  cp_status="$("$CONTROL_PLANE_STATUS_SCRIPT" || true)"
  echo "control-plane-status=${cp_status:-offline}"
fi

echo "opening Dev Station..."
open "$APP_PATH" --args --start-view "$START_VIEW" --roundup "$ROUNDUP_MODE" --station "$SODS_BASE_URL"
echo "OK"
