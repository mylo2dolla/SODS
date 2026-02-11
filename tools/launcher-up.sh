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
TOKEN_CHECK_URL="${TOKEN_URL:-${TOKEN_ENDPOINT:-}}"
GOD_HEALTH_CHECK_URL="${GOD_HEALTH_URL:-${GOD_GATEWAY_URL:-}}"
VAULT_HEALTH_CHECK_URL="${VAULT_HEALTH_URL:-${VAULT_INGEST_URL:-}}"
OPS_HEALTH_CHECK_URL="${OPS_FEED_HEALTH_URL:-${OPS_FEED_URL:-}}"

APP_PATH="${DEVSTATION_APP_PATH:-$REPO_ROOT/dist/DevStation.app}"
START_VIEW="${DEVSTATION_START_VIEW:-dashboard}"
ROUNDUP_MODE="${DEVSTATION_ROUNDUP_MODE:-connect-identify}"

exec >>"$LOG_FILE" 2>&1
echo "=== launcher-up $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
echo "repo=$REPO_ROOT"
echo "station=$SODS_BASE_URL"
echo "port=$SODS_PORT"

normalize_health_url() {
  local raw="${1:-}"
  if [[ -z "$raw" ]]; then
    return 0
  fi
  echo "$raw" | sed -E 's#/v1/ingest/?$#/health#; s#/god/?$#/health#'
}

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

check_http_get() {
  local label="$1"
  local url="$2"
  if [[ -z "$url" ]]; then
    echo "WARN $label not configured"
    return 1
  fi
  if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
    echo "OK   $label $url"
    return 0
  fi
  echo "WARN $label unreachable $url"
  return 1
}

check_token() {
  if [[ -z "$TOKEN_CHECK_URL" ]]; then
    echo "WARN token endpoint not configured"
    return 1
  fi
  local response=""
  response="$(curl -fsS --max-time 3 -X POST "$TOKEN_CHECK_URL" -H 'content-type: application/json' -d '{"identity":"devstation-launcher","room":"strangelab"}' 2>/dev/null || true)"
  if [[ "$response" == *"token"* ]]; then
    echo "OK   token endpoint $TOKEN_CHECK_URL"
    return 0
  fi
  echo "WARN token endpoint unreachable or invalid response $TOKEN_CHECK_URL"
  return 1
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

echo "running stack probes..."
STATION_HEALTH_URL="${SODS_BASE_URL%/}/health"
GOD_HEALTH_CHECK_URL="$(normalize_health_url "$GOD_HEALTH_CHECK_URL")"
VAULT_HEALTH_CHECK_URL="$(normalize_health_url "$VAULT_HEALTH_CHECK_URL")"
OPS_HEALTH_CHECK_URL="$(normalize_health_url "$OPS_HEALTH_CHECK_URL")"
check_http_get "station" "$STATION_HEALTH_URL" || true
check_http_get "vault" "$VAULT_HEALTH_CHECK_URL" || true
check_http_get "god-gateway" "$GOD_HEALTH_CHECK_URL" || true
check_http_get "ops-feed" "$OPS_HEALTH_CHECK_URL" || true
check_token || true

echo "opening Dev Station..."
open "$APP_PATH" --args --start-view "$START_VIEW" --roundup "$ROUNDUP_MODE" --station "$SODS_BASE_URL"
echo "OK"
