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

TOKEN_CHECK_URL="${TOKEN_URL:-http://192.168.8.114:9123/token}"
GOD_HEALTH_URL="${GOD_HEALTH_URL:-http://192.168.8.114:8099/health}"
OPS_HEALTH_URL="${OPS_FEED_HEALTH_URL:-${OPS_FEED_URL:-http://192.168.8.114:9101}/health}"
VAULT_HEALTH_URL="${VAULT_HEALTH_URL:-${VAULT_URL:-http://192.168.8.160:8088/v1/ingest}}"

normalize_health_url() {
  local raw="${1:-}"
  if [[ -z "$raw" ]]; then
    printf '%s' ""
    return 0
  fi
  echo "$raw" | sed -E 's#/v1/ingest/?$#/health#; s#/god/?$#/health#; s#//health/?$#/health#'
}

GOD_HEALTH_URL="$(normalize_health_url "$GOD_HEALTH_URL")"
OPS_HEALTH_URL="$(normalize_health_url "$OPS_HEALTH_URL")"
VAULT_HEALTH_URL="$(normalize_health_url "$VAULT_HEALTH_URL")"

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
  ssh "${SSH_FLAGS[@]}" "$target" "echo ok" >/dev/null 2>&1
}

resolve_ssh_target() {
  local out_var="$1"
  shift
  local selected=""
  local candidate
  for candidate in "$@"; do
    if [[ -z "$candidate" ]]; then
      continue
    fi
    if probe_ssh_target "$candidate"; then
      selected="$candidate"
      break
    fi
  done
  printf -v "$out_var" '%s' "$selected"
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
  if [[ -z "$install_host" ]]; then
    return 1
  fi
  (
    cd "$REPO_ROOT/ops/strangelab-control-plane"
    ./scripts/push-and-install-remote.sh "$install_host" "$profile"
  )
}

check_http_endpoint() {
  local name="$1"
  local url="$2"
  local services_file="$3"
  if [[ -z "$url" ]]; then
    add_service_line "$services_file" "$name" "0" "url-not-configured"
    return 1
  fi
  if curl -fsS --max-time 4 "$url" >/dev/null 2>&1; then
    add_service_line "$services_file" "$name" "1" "$url"
    return 0
  fi
  add_service_line "$services_file" "$name" "0" "$url unreachable"
  return 1
}

check_token_endpoint() {
  local url="$1"
  local services_file="$2"
  local response=""
  if response="$(curl -fsS --max-time 4 -X POST "$url" -H 'content-type: application/json' -d '{"identity":"control-plane-up","room":"strangelab"}' 2>/dev/null)"; then
    if [[ "$response" == *"token"* ]]; then
      add_service_line "$services_file" "token-endpoint" "1" "$url"
      return 0
    fi
    add_service_line "$services_file" "token-endpoint" "0" "$url invalid-response"
    return 1
  fi
  add_service_line "$services_file" "token-endpoint" "0" "$url unreachable"
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

  local unit
  local all_ok=1
  local had_inactive=0

  declare -A status_map=()
  declare -A detail_map=()

  for unit in "${units[@]}"; do
    local state
    state="$(remote_unit_state "$target" "$unit")"
    if [[ "$state" == "active" ]]; then
      status_map["$unit"]="1"
      detail_map["$unit"]="active"
    else
      status_map["$unit"]="0"
      detail_map["$unit"]="state=${state:-unknown}"
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
      local state
      state="$(remote_unit_state "$target" "$unit")"
      if [[ "$state" == "active" ]]; then
        status_map["$unit"]="1"
        detail_map["$unit"]="active-after-restart"
      else
        status_map["$unit"]="0"
        detail_map["$unit"]="state=${state:-unknown}-after-restart"
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

    for unit in "${units[@]}"; do
      local state
      state="$(remote_unit_state "$target" "$unit")"
      if [[ "$state" == "active" ]]; then
        status_map["$unit"]="1"
        detail_map["$unit"]="active-after-bootstrap"
      else
        status_map["$unit"]="0"
        detail_map["$unit"]="state=${state:-unknown}-after-bootstrap"
      fi
    done
  fi

  for unit in "${units[@]}"; do
    local unit_ok="${status_map[$unit]:-0}"
    local unit_detail="${detail_map[$unit]:-unknown}"
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
  resolve_ssh_target selected "aux" "pi@192.168.8.114"

  local reachable=0
  local ok=0

  if [[ -z "$selected" ]]; then
    add_action_line "$actions_file" "unreachable:ssh-candidates=aux,pi@192.168.8.114"
    add_service_line "$services_file" "strangelab-token.service" "0" "host-unreachable"
    add_service_line "$services_file" "strangelab-god-gateway.service" "0" "host-unreachable"
    add_service_line "$services_file" "strangelab-ops-feed.service" "0" "host-unreachable"
    add_service_line "$services_file" "strangelab-exec-agent@pi-aux.service" "0" "host-unreachable"
    add_service_line "$services_file" "token-endpoint" "0" "host-unreachable"
    add_service_line "$services_file" "god-health" "0" "host-unreachable"
    add_service_line "$services_file" "ops-feed-health" "0" "host-unreachable"
  else
    reachable=1
    add_action_line "$actions_file" "ssh-target:${selected}"

    local units_ok=1
    if ! reconcile_systemd_units "$selected" "$services_file" "$actions_file" "pi-aux" "$selected" \
      "strangelab-token.service" \
      "strangelab-god-gateway.service" \
      "strangelab-ops-feed.service" \
      "strangelab-exec-agent@pi-aux.service"; then
      units_ok=0
    fi

    local endpoints_ok=1
    if ! check_token_endpoint "$TOKEN_CHECK_URL" "$services_file"; then
      endpoints_ok=0
    fi
    if ! check_http_endpoint "god-health" "$GOD_HEALTH_URL" "$services_file"; then
      endpoints_ok=0
    fi
    if ! check_http_endpoint "ops-feed-health" "$OPS_HEALTH_URL" "$services_file"; then
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
  resolve_ssh_target selected "vault" "pi@192.168.8.160"

  local reachable=0
  local ok=0

  if [[ -z "$selected" ]]; then
    add_action_line "$actions_file" "unreachable:ssh-candidates=vault,pi@192.168.8.160"
    add_service_line "$services_file" "strangelab-vault-ingest.service" "0" "host-unreachable"
    add_service_line "$services_file" "strangelab-exec-agent@pi-logger.service" "0" "host-unreachable"
    add_service_line "$services_file" "vault-health" "0" "host-unreachable"
  else
    reachable=1
    add_action_line "$actions_file" "ssh-target:${selected}"

    local vault_state
    vault_state="$(remote_unit_state "$selected" "strangelab-vault-ingest.service")"
    local exec_tpl_state
    exec_tpl_state="$(remote_unit_state "$selected" "strangelab-exec-agent@pi-logger.service")"
    local exec_fallback_state
    exec_fallback_state="$(remote_unit_state "$selected" "strangelab-exec-agent.service")"

    local vault_ok=0
    local exec_ok=0

    if [[ "$vault_state" == "active" ]]; then
      vault_ok=1
    fi
    if [[ "$exec_tpl_state" == "active" || "$exec_fallback_state" == "active" ]]; then
      exec_ok=1
    fi

    if (( vault_ok == 0 || exec_ok == 0 )); then
      add_action_line "$actions_file" "restart-systemd:pi-logger"
      if remote_cmd "$selected" "sudo systemctl restart strangelab-vault-ingest.service strangelab-exec-agent@pi-logger.service strangelab-exec-agent.service" >/dev/null 2>&1; then
        add_action_line "$actions_file" "restart-systemd:ok"
      else
        add_action_line "$actions_file" "restart-systemd:failed"
      fi
      vault_state="$(remote_unit_state "$selected" "strangelab-vault-ingest.service")"
      exec_tpl_state="$(remote_unit_state "$selected" "strangelab-exec-agent@pi-logger.service")"
      exec_fallback_state="$(remote_unit_state "$selected" "strangelab-exec-agent.service")"
      vault_ok=$([[ "$vault_state" == "active" ]] && echo 1 || echo 0)
      if [[ "$exec_tpl_state" == "active" || "$exec_fallback_state" == "active" ]]; then
        exec_ok=1
      else
        exec_ok=0
      fi
    fi

    if (( vault_ok == 0 || exec_ok == 0 )); then
      add_action_line "$actions_file" "bootstrap-install:pi-logger@${selected}"
      if run_bootstrap_profile "$selected" "pi-logger" >/dev/null 2>&1; then
        add_action_line "$actions_file" "bootstrap-install:ok"
      else
        add_action_line "$actions_file" "bootstrap-install:failed"
      fi
      vault_state="$(remote_unit_state "$selected" "strangelab-vault-ingest.service")"
      exec_tpl_state="$(remote_unit_state "$selected" "strangelab-exec-agent@pi-logger.service")"
      exec_fallback_state="$(remote_unit_state "$selected" "strangelab-exec-agent.service")"
      vault_ok=$([[ "$vault_state" == "active" ]] && echo 1 || echo 0)
      if [[ "$exec_tpl_state" == "active" || "$exec_fallback_state" == "active" ]]; then
        exec_ok=1
      else
        exec_ok=0
      fi
    fi

    add_service_line "$services_file" "strangelab-vault-ingest.service" "$vault_ok" "state=${vault_state:-unknown}"
    if [[ "$exec_tpl_state" == "active" ]]; then
      add_service_line "$services_file" "strangelab-exec-agent@pi-logger.service" "1" "state=active"
    elif [[ "$exec_fallback_state" == "active" ]]; then
      add_service_line "$services_file" "strangelab-exec-agent@pi-logger.service" "1" "fallback=strangelab-exec-agent.service"
    else
      add_service_line "$services_file" "strangelab-exec-agent@pi-logger.service" "0" "state=${exec_tpl_state:-unknown};fallback=${exec_fallback_state:-unknown}"
    fi

    local vault_health_ok=1
    if ! check_http_endpoint "vault-health" "$VAULT_HEALTH_URL" "$services_file"; then
      vault_health_ok=0
    fi

    if (( vault_ok == 1 && exec_ok == 1 && vault_health_ok == 1 )); then
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

  local candidates=(
    "mac8"
    "mac16"
    "${MAC8_SSH_TARGET:-}"
    "${MAC16_SSH_TARGET:-}"
    "${MAC8_SSH:-}"
    "${MAC16_SSH:-}"
  )

  local selected=""
  resolve_ssh_target selected "${candidates[@]}"

  local reachable=0
  local ok=0
  if [[ -z "$selected" ]]; then
    add_action_line "$actions_file" "unreachable:ssh-candidates=mac8,mac16,configured"
    add_service_line "$services_file" "com.strangelab.exec-agent.mac2" "0" "host-unreachable"
    add_service_line "$services_file" "com.strangelab.exec-agent.mac1" "0" "host-unreachable"
  else
    reachable=1
    add_action_line "$actions_file" "ssh-target:${selected}"

    local mac2_ok=0
    local mac1_ok=0
    if remote_cmd "$selected" "launchctl print system/com.strangelab.exec-agent.mac2 >/dev/null 2>&1"; then
      mac2_ok=1
    fi
    if remote_cmd "$selected" "launchctl print system/com.strangelab.exec-agent.mac1 >/dev/null 2>&1"; then
      mac1_ok=1
    fi

    if (( mac2_ok == 0 && mac1_ok == 0 )); then
      add_action_line "$actions_file" "kickstart-launchd:mac1+mac2"
      remote_cmd "$selected" "sudo launchctl kickstart -k system/com.strangelab.exec-agent.mac2 >/dev/null 2>&1 || true; sudo launchctl kickstart -k system/com.strangelab.exec-agent.mac1 >/dev/null 2>&1 || true; launchctl kickstart -k system/com.strangelab.exec-agent.mac2 >/dev/null 2>&1 || true; launchctl kickstart -k system/com.strangelab.exec-agent.mac1 >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
      if remote_cmd "$selected" "launchctl print system/com.strangelab.exec-agent.mac2 >/dev/null 2>&1"; then
        mac2_ok=1
      fi
      if remote_cmd "$selected" "launchctl print system/com.strangelab.exec-agent.mac1 >/dev/null 2>&1"; then
        mac1_ok=1
      fi
    fi

    add_service_line "$services_file" "com.strangelab.exec-agent.mac2" "$mac2_ok" "$([[ "$mac2_ok" == "1" ]] && echo active || echo inactive)"
    add_service_line "$services_file" "com.strangelab.exec-agent.mac1" "$mac1_ok" "$([[ "$mac1_ok" == "1" ]] && echo active || echo inactive)"

    if (( mac2_ok == 1 || mac1_ok == 1 )); then
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
log "god=$GOD_HEALTH_URL"
log "ops=$OPS_HEALTH_URL"
log "vault=$VAULT_HEALTH_URL"

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
