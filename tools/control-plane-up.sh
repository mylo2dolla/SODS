#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -f "$REPO_ROOT/tools/_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/tools/_env.sh"
fi

LOG_DIR="$HOME/Library/Logs/SODS"
STATUS_FILE="$LOG_DIR/control-plane-status.json"
LOG_FILE="$LOG_DIR/control-plane-up.log"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

timestamp_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
  printf '[%s] %s\n' "$(timestamp_utc)" "$*"
}

SSH_FLAGS=(
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=accept-new
)

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/control-plane-up.XXXXXX")"
TARGET_JSONL="$TMP_DIR/targets.jsonl"
: > "$TARGET_JSONL"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

TOTAL_TARGETS=0
OK_TARGETS=0
REACHABLE_TARGETS=0

TOKEN_CHECK_URL="${TOKEN_URL:-http://${AUX_HOST:-192.168.8.114}:9123/token}"
TOKEN_HEALTH_CHECK_URL="${TOKEN_HEALTH_URL:-http://${AUX_HOST:-192.168.8.114}:9123/health}"
GOD_HEALTH_CHECK_URL="${GOD_HEALTH_URL:-http://${AUX_HOST:-192.168.8.114}:8099/health}"
OPS_HEALTH_CHECK_URL="${OPS_FEED_HEALTH_URL:-http://${AUX_HOST:-192.168.8.114}:9101/health}"
VAULT_HEALTH_CHECK_URL="${VAULT_HEALTH_URL:-http://${LOGGER_HOST:-192.168.8.169}:8088/health}"

normalize_health_url() {
  local raw="${1:-}"
  if [[ -z "$raw" ]]; then
    printf '%s' ""
    return 0
  fi
  echo "$raw" | sed -E 's#/v1/ingest/?$#/health#; s#/god/?$#/health#; s#//health/?$#/health#'
}

resolve_ipv4_host() {
  local host="${1:-}"
  if [[ -z "$host" ]]; then
    printf '%s' ""
    return 0
  fi
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

url_host() {
  local raw="${1:-}"
  if [[ -z "$raw" ]]; then
    printf '%s' ""
    return 0
  fi
  python3 - "$raw" <<'PY'
from urllib.parse import urlsplit
import sys
url = sys.argv[1]
try:
    print(urlsplit(url).hostname or "")
except Exception:
    print("")
PY
}

url_with_host() {
  local raw="${1:-}"
  local new_host="${2:-}"
  if [[ -z "$raw" || -z "$new_host" ]]; then
    printf '%s' ""
    return 0
  fi
  python3 - "$raw" "$new_host" <<'PY'
from urllib.parse import urlsplit, urlunsplit
import sys
url = sys.argv[1]
new_host = sys.argv[2]
try:
    parts = urlsplit(url)
    if not parts.scheme:
      print("")
      raise SystemExit
    netloc = new_host
    if parts.port:
      netloc = f"{new_host}:{parts.port}"
    print(urlunsplit((parts.scheme, netloc, parts.path, parts.query, parts.fragment)))
except Exception:
    print("")
PY
}

endpoint_candidates() {
  local configured_url="${1:-}"
  if [[ -z "$configured_url" ]]; then
    return 0
  fi
  printf '%s\n' "$configured_url"
  local host resolved_url resolved_ip
  host="$(url_host "$configured_url")"
  resolved_ip="$(resolve_ipv4_host "$host")"
  if [[ -n "$resolved_ip" && -n "$host" && "$resolved_ip" != "$host" ]]; then
    resolved_url="$(url_with_host "$configured_url" "$resolved_ip")"
    if [[ -n "$resolved_url" ]]; then
      printf '%s\n' "$resolved_url"
    fi
  fi
}

GOD_HEALTH_CHECK_URL="$(normalize_health_url "$GOD_HEALTH_CHECK_URL")"
OPS_HEALTH_CHECK_URL="$(normalize_health_url "$OPS_HEALTH_CHECK_URL")"
VAULT_HEALTH_CHECK_URL="$(normalize_health_url "$VAULT_HEALTH_CHECK_URL")"

add_service_line() {
  local file="$1"
  local name="$2"
  local ok="$3"
  local detail="$4"
  printf '%s\t%s\t%s\n' "$name" "$ok" "$detail" >> "$file"
}

add_action_line() {
  local file="$1"
  local action="$2"
  printf '%s\n' "$action" >> "$file"
}

emit_target_json() {
  local name="$1"
  local reachable="$2"
  local ok="$3"
  local services_file="$4"
  local actions_file="$5"
  python3 - "$name" "$reachable" "$ok" "$services_file" "$actions_file" >> "$TARGET_JSONL" <<'PY'
import json
import pathlib
import sys

name, reachable_raw, ok_raw, services_path, actions_path = sys.argv[1:6]
reachable = reachable_raw == "1"
ok = ok_raw == "1"

services = []
for raw in pathlib.Path(services_path).read_text().splitlines():
    if not raw:
        continue
    parts = raw.split("\t", 2)
    if len(parts) == 3:
        svc_name, svc_ok_raw, svc_detail = parts
    elif len(parts) == 2:
        svc_name, svc_ok_raw = parts
        svc_detail = ""
    else:
        svc_name = parts[0]
        svc_ok_raw = "0"
        svc_detail = ""
    svc_ok = str(svc_ok_raw).lower() in {"1", "true", "ok", "active"}
    services.append({"name": svc_name, "ok": svc_ok, "detail": svc_detail})

actions = [line for line in pathlib.Path(actions_path).read_text().splitlines() if line]
obj = {
    "name": name,
    "reachable": reachable,
    "ok": ok,
    "services": services,
    "actions": actions,
}
print(json.dumps(obj))
PY
}

record_target() {
  local name="$1"
  local reachable="$2"
  local ok="$3"
  TOTAL_TARGETS=$((TOTAL_TARGETS + 1))
  if [[ "$reachable" == "1" ]]; then
    REACHABLE_TARGETS=$((REACHABLE_TARGETS + 1))
  fi
  if [[ "$ok" == "1" ]]; then
    OK_TARGETS=$((OK_TARGETS + 1))
  fi
  log "target=$name reachable=$reachable ok=$ok"
}

probe_ssh_target() {
  local target="$1"
  [[ -n "$target" ]] || return 1
  ssh "${SSH_FLAGS[@]}" "$target" "echo ok" >/dev/null 2>&1
}

resolve_ssh_target() {
  local out_var="$1"
  shift
  local resolved=""
  local candidate
  for candidate in "$@"; do
    [[ -n "$candidate" ]] || continue
    if probe_ssh_target "$candidate"; then
      resolved="$candidate"
      break
    fi
  done
  printf -v "$out_var" '%s' "$resolved"
}

remote_cmd() {
  local target="$1"
  local command="$2"
  ssh "${SSH_FLAGS[@]}" "$target" "$command"
}

remote_unit_state() {
  local target="$1"
  local unit="$2"
  remote_cmd "$target" "sudo systemctl is-active '$unit' 2>/dev/null || true" 2>/dev/null | tr -d '\r\n'
}

run_bootstrap_profile() {
  local install_host="$1"
  local profile="$2"
  local installer="$REPO_ROOT/ops/strangelab-control-plane/scripts/push-and-install-remote.sh"
  if [[ -z "$install_host" || ! -x "$installer" ]]; then
    return 1
  fi
  (
    cd "$REPO_ROOT/ops/strangelab-control-plane"
    ./scripts/push-and-install-remote.sh "$install_host" "$profile"
  )
}

json_payload_ok() {
  local payload="$1"
  python3 - "$payload" <<'PY'
import json, sys
text = sys.argv[1]
try:
    obj = json.loads(text)
except Exception:
    sys.exit(1)
sys.exit(0 if obj.get("ok") is True else 1)
PY
}

check_http_endpoint() {
  local name="$1"
  local url="$2"
  local services_file="$3"
  if [[ -z "$url" ]]; then
    add_service_line "$services_file" "$name" "0" "url-not-configured"
    return 1
  fi

  local attempts=""
  local success_url=""
  local candidates candidate response code body
  candidates="$(endpoint_candidates "$url")"

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    response="$(curl -sS --max-time 5 -w '\n__HTTP_CODE__:%{http_code}' "$candidate" 2>/dev/null || true)"
    code="$(printf '%s\n' "$response" | sed -n 's/^__HTTP_CODE__:\([0-9][0-9][0-9]\)$/\1/p' | tail -n 1)"
    body="$(printf '%s\n' "$response" | sed '/^__HTTP_CODE__:[0-9][0-9][0-9]$/d')"
    if [[ -n "$attempts" ]]; then
      attempts="${attempts}; "
    fi
    attempts="${attempts}${candidate} http=${code:-none}"
    if [[ "$code" == "200" ]] && json_payload_ok "$body"; then
      success_url="$candidate"
    fi
  done <<< "$candidates"

  if [[ -n "$success_url" ]]; then
    add_service_line "$services_file" "$name" "1" "ok endpoint=${success_url}; attempted=${attempts}"
    return 0
  fi

  add_service_line "$services_file" "$name" "0" "invalid-or-unreachable; attempted=${attempts}"
  return 1
}

check_token_endpoint() {
  local url="$1"
  local services_file="$2"
  local attempts=""
  local success_url=""
  local candidates candidate response code body
  candidates="$(endpoint_candidates "$url")"

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    response="$(curl -sS --max-time 5 -X POST -H 'content-type: application/json' -d '{"identity":"control-plane-up","room":"strangelab"}' -w '\n__HTTP_CODE__:%{http_code}' "$candidate" 2>/dev/null || true)"
    code="$(printf '%s\n' "$response" | sed -n 's/^__HTTP_CODE__:\([0-9][0-9][0-9]\)$/\1/p' | tail -n 1)"
    body="$(printf '%s\n' "$response" | sed '/^__HTTP_CODE__:[0-9][0-9][0-9]$/d')"
    if [[ -n "$attempts" ]]; then
      attempts="${attempts}; "
    fi
    attempts="${attempts}${candidate} http=${code:-none}"
    if [[ "$code" == "200" && "$body" == *'"token"'* ]]; then
      success_url="$candidate"
    fi
  done <<< "$candidates"

  if [[ -n "$success_url" ]]; then
    add_service_line "$services_file" "token-endpoint" "1" "ok endpoint=${success_url}; attempted=${attempts}"
    return 0
  fi

  add_service_line "$services_file" "token-endpoint" "0" "invalid-or-unreachable; attempted=${attempts}"
  return 1
}

check_remote_health_endpoint() {
  local target="$1"
  local name="$2"
  local url="$3"
  local services_file="$4"
  if [[ -z "$url" ]]; then
    add_service_line "$services_file" "$name" "0" "url-not-configured"
    return 1
  fi
  local response code body
  response="$(remote_cmd "$target" "curl -sS --max-time 5 -w '\n__HTTP_CODE__:%{http_code}' '$url'" 2>/dev/null || true)"
  code="$(printf '%s\n' "$response" | sed -n 's/^__HTTP_CODE__:\([0-9][0-9][0-9]\)$/\1/p' | tail -n 1)"
  body="$(printf '%s\n' "$response" | sed '/^__HTTP_CODE__:[0-9][0-9][0-9]$/d')"

  if [[ "$code" == "401" ]]; then
    add_service_line "$services_file" "$name" "1" "$url auth-required"
    return 0
  fi
  if [[ "$code" == "200" ]] && json_payload_ok "$body"; then
    add_service_line "$services_file" "$name" "1" "$url"
    return 0
  fi
  add_service_line "$services_file" "$name" "0" "$url invalid-or-unreachable http=${code:-none}"
  return 1
}

reconcile_systemd_units() {
  local target="$1"
  local services_file="$2"
  local actions_file="$3"
  local install_profile="$4"
  local install_host="$5"
  shift 5
  local units=("$@")

  local all_ok=1
  local had_inactive=0
  local unit state

  for unit in "${units[@]}"; do
    state="$(remote_unit_state "$target" "$unit")"
    if [[ "$state" != "active" ]]; then
      had_inactive=1
    fi
  done

  if (( had_inactive == 1 )); then
    add_action_line "$actions_file" "restart-systemd:${units[*]}"
    if remote_cmd "$target" "sudo systemctl restart ${units[*]}" >/dev/null 2>&1; then
      add_action_line "$actions_file" "restart-systemd:ok"
    else
      add_action_line "$actions_file" "restart-systemd:failed"
    fi

    had_inactive=0
    for unit in "${units[@]}"; do
      state="$(remote_unit_state "$target" "$unit")"
      if [[ "$state" != "active" ]]; then
        had_inactive=1
      fi
    done
  fi

  if (( had_inactive == 1 )); then
    add_action_line "$actions_file" "bootstrap-install:${install_profile}@${install_host}"
    if run_bootstrap_profile "$install_host" "$install_profile" >/dev/null 2>&1; then
      add_action_line "$actions_file" "bootstrap-install:ok"
    else
      add_action_line "$actions_file" "bootstrap-install:failed"
    fi
  fi

  for unit in "${units[@]}"; do
    state="$(remote_unit_state "$target" "$unit")"
    local unit_ok=0
    local unit_detail="state=${state:-unknown}"
    if [[ "$state" == "active" ]]; then
      unit_ok=1
      unit_detail="active"
    fi
    add_service_line "$services_file" "$unit" "$unit_ok" "$unit_detail"
    if [[ "$unit_ok" != "1" ]]; then
      all_ok=0
    fi
  done

  if [[ "$all_ok" == "1" ]]; then
    return 0
  fi
  return 1
}

process_pi_aux() {
  local services_file="$TMP_DIR/pi-aux.services"
  local actions_file="$TMP_DIR/pi-aux.actions"
  : > "$services_file"
  : > "$actions_file"

  local selected=""
  resolve_ssh_target selected \
    "${AUX_SSH_TARGET:-}" \
    "${AUX_SSH_ALIAS:-aux}" \
    "${AUX_SSH:-}" \
    "aux" \
    "pi@${AUX_HOST:-192.168.8.114}"

  local reachable=0
  local ok=0

  if [[ -z "$selected" ]]; then
    add_action_line "$actions_file" "unreachable:ssh-candidates=aux,${AUX_SSH_TARGET:-},${AUX_SSH:-}"
    add_service_line "$services_file" "strangelab-codegatchi-tunnel.service" "0" "host-unreachable"
    add_service_line "$services_file" "strangelab-token.service" "0" "host-unreachable"
    add_service_line "$services_file" "strangelab-god-gateway.service" "0" "host-unreachable"
    add_service_line "$services_file" "strangelab-ops-feed.service" "0" "host-unreachable"
    add_service_line "$services_file" "token-endpoint" "0" "host-unreachable"
    add_service_line "$services_file" "token-health" "0" "host-unreachable"
    add_service_line "$services_file" "god-health" "0" "host-unreachable"
    add_service_line "$services_file" "ops-feed-health" "0" "host-unreachable"
    add_service_line "$services_file" "codegatchi-tunnel-health" "0" "host-unreachable"
  else
    reachable=1
    add_action_line "$actions_file" "ssh-target:${selected}"

    local units_ok=1
    if ! reconcile_systemd_units "$selected" "$services_file" "$actions_file" "pi-aux" "$selected" \
      "strangelab-codegatchi-tunnel.service" \
      "strangelab-token.service" \
      "strangelab-god-gateway.service" \
      "strangelab-ops-feed.service"; then
      units_ok=0
    fi

    local endpoints_ok=1
    if ! check_token_endpoint "$TOKEN_CHECK_URL" "$services_file"; then
      endpoints_ok=0
    fi
    if ! check_http_endpoint "token-health" "$TOKEN_HEALTH_CHECK_URL" "$services_file"; then
      endpoints_ok=0
    fi
    if ! check_http_endpoint "god-health" "$GOD_HEALTH_CHECK_URL" "$services_file"; then
      endpoints_ok=0
    fi
    if ! check_http_endpoint "ops-feed-health" "$OPS_HEALTH_CHECK_URL" "$services_file"; then
      endpoints_ok=0
    fi
    if ! check_remote_health_endpoint "$selected" "codegatchi-tunnel-health" "$FED_GATEWAY_HEALTH_URL" "$services_file"; then
      endpoints_ok=0
    fi

    if (( units_ok == 1 && endpoints_ok == 1 )); then
      ok=1
    fi
  fi

  emit_target_json "pi-aux" "$reachable" "$ok" "$services_file" "$actions_file"
  record_target "pi-aux" "$reachable" "$ok"
}

process_pi_logger() {
  local services_file="$TMP_DIR/pi-logger.services"
  local actions_file="$TMP_DIR/pi-logger.actions"
  : > "$services_file"
  : > "$actions_file"

  local selected=""
  resolve_ssh_target selected \
    "${VAULT_SSH_TARGET:-}" \
    "${VAULT_SSH_ALIAS:-vault}" \
    "${VAULT_SSH:-}" \
    "vault" \
    "pi@${LOGGER_HOST:-192.168.8.169}"

  local reachable=0
  local ok=0

  if [[ -z "$selected" ]]; then
    add_action_line "$actions_file" "unreachable:ssh-candidates=vault,${VAULT_SSH_TARGET:-},${VAULT_SSH:-}"
    add_service_line "$services_file" "strangelab-vault-ingest.service" "0" "host-unreachable"
    add_service_line "$services_file" "vault-events-dir" "0" "host-unreachable"
    add_service_line "$services_file" "vault-health" "0" "host-unreachable"
  else
    reachable=1
    add_action_line "$actions_file" "ssh-target:${selected}"

    local units_ok=1
    if ! reconcile_systemd_units "$selected" "$services_file" "$actions_file" "pi-logger" "$selected" \
      "strangelab-vault-ingest.service"; then
      units_ok=0
    fi

    local events_dir_ok=0
    if remote_cmd "$selected" "test -d /vault/sods/vault/events" >/dev/null 2>&1; then
      events_dir_ok=1
      add_service_line "$services_file" "vault-events-dir" "1" "/vault/sods/vault/events"
    else
      add_service_line "$services_file" "vault-events-dir" "0" "/vault/sods/vault/events missing"
    fi

    local health_ok=1
    if ! check_http_endpoint "vault-health" "$VAULT_HEALTH_CHECK_URL" "$services_file"; then
      health_ok=0
    fi

    if (( units_ok == 1 && events_dir_ok == 1 && health_ok == 1 )); then
      ok=1
    fi
  fi

  emit_target_json "pi-logger" "$reachable" "$ok" "$services_file" "$actions_file"
  record_target "pi-logger" "$reachable" "$ok"
}

process_mac_agents() {
  local services_file="$TMP_DIR/mac-agents.services"
  local actions_file="$TMP_DIR/mac-agents.actions"
  : > "$services_file"
  : > "$actions_file"

  local selected=""
  resolve_ssh_target selected \
    "${MAC16_SSH_TARGET:-}" \
    "${MAC16_SSH_ALIAS:-mac16}" \
    "${MAC16_SSH:-}" \
    "mac16" \
    "letsdev@${MAC16_HOST:-mac16.local}" \
    "${MAC8_SSH_TARGET:-}" \
    "${MAC8_SSH_ALIAS:-mac8}" \
    "${MAC8_SSH:-}" \
    "mac8"

  local reachable=0
  local ok=0
  if [[ -z "$selected" ]]; then
    add_action_line "$actions_file" "unreachable:ssh-candidates=mac16,mac8,configured"
    add_service_line "$services_file" "codegatchi-health" "0" "host-unreachable"
  else
    reachable=1
    add_action_line "$actions_file" "ssh-target:${selected}"

    if check_remote_health_endpoint "$selected" "codegatchi-health" "http://127.0.0.1:9777/v1/health" "$services_file"; then
      ok=1
    fi
  fi

  emit_target_json "mac-agents" "$reachable" "$ok" "$services_file" "$actions_file"
  record_target "mac-agents" "$reachable" "$ok"
}

write_status_file() {
  local overall="$1"
  local ts="$2"
  local tmp_file="$STATUS_FILE.tmp"
  python3 - "$TARGET_JSONL" "$tmp_file" "$overall" "$ts" <<'PY'
import json
import pathlib
import sys

target_jsonl, out_path, overall, ts = sys.argv[1:5]
targets = []
for raw in pathlib.Path(target_jsonl).read_text().splitlines():
    raw = raw.strip()
    if not raw:
        continue
    targets.append(json.loads(raw))

payload = {
    "ts": ts,
    "overall": overall,
    "targets": targets,
}
pathlib.Path(out_path).write_text(json.dumps(payload, indent=2) + "\n")
PY
  mv "$tmp_file" "$STATUS_FILE"
}

print_summary_table() {
  python3 - "$STATUS_FILE" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
print("")
print("Control Plane Fleet Summary")
print("---------------------------")
print(f"overall: {data.get('overall', 'offline')}  ts: {data.get('ts', '')}")
print("")
print(f"{'target':16} {'reachable':10} {'ok':6} {'failed_checks':13}")
for target in data.get("targets", []):
    name = target.get("name", "")
    reachable = "yes" if target.get("reachable") else "no"
    ok = "yes" if target.get("ok") else "no"
    failed = sum(1 for svc in target.get("services", []) if not svc.get("ok"))
    print(f"{name:16} {reachable:10} {ok:6} {failed:13}")
print("")
PY
}

log "=== control-plane-up start ==="
log "repo=$REPO_ROOT"
log "token=$TOKEN_CHECK_URL"
log "token-health=$TOKEN_HEALTH_CHECK_URL"
log "god=$GOD_HEALTH_CHECK_URL"
log "ops=$OPS_HEALTH_CHECK_URL"
log "vault=$VAULT_HEALTH_CHECK_URL"

process_pi_aux
process_pi_logger
process_mac_agents

OVERALL="degraded"
if (( TOTAL_TARGETS > 0 && OK_TARGETS == TOTAL_TARGETS )); then
  OVERALL="ok"
elif (( REACHABLE_TARGETS == 0 )); then
  OVERALL="offline"
fi

TS_NOW="$(timestamp_utc)"
write_status_file "$OVERALL" "$TS_NOW"
print_summary_table

log "status-file=$STATUS_FILE"
log "overall=$OVERALL total=$TOTAL_TARGETS ok=$OK_TARGETS reachable=$REACHABLE_TARGETS"
log "=== control-plane-up done ==="

if [[ "$OVERALL" == "ok" ]]; then
  exit 0
fi
exit 1
