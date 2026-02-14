#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_BUNDLE="$REPO_ROOT/dist/DerivedData/Build/Products/Debug/DevStation.app"
APP_BIN="$APP_BUNDLE/Contents/MacOS/DevStation"
DERIVED_DATA_PATH="$REPO_ROOT/dist/DerivedData"
REPORT_DIR="$HOME/Library/Logs/DiagnosticReports"

SAMPLE_SECONDS="${SODS_DEVSTATION_PERF_SAMPLE_SECONDS:-45}"
BOOT_TIMEOUT_SECONDS="${SODS_DEVSTATION_PERF_BOOT_TIMEOUT_SECONDS:-20}"
HEARTBEAT_STALE_SECONDS="${SODS_DEVSTATION_PERF_HEARTBEAT_STALE_SECONDS:-3}"
CPU_MAX_AVG="${SODS_DEVSTATION_PERF_CPU_MAX_AVG:-140}"
RSS_MAX_KB="${SODS_DEVSTATION_PERF_RSS_MAX_KB:-900000}"
RSS_DELTA_MAX_KB="${SODS_DEVSTATION_PERF_RSS_DELTA_MAX_KB:-350000}"
STATION_URL="${SODS_DEVSTATION_PERF_STATION_URL:-http://127.0.0.1:9123}"

sample_interval=1
app_pid=""
run_id=""
heartbeat_file=""
launch_log=""
pre_reports_file=""
post_reports_file=""

fail() {
  echo "check-devstation-performance: FAIL: $*" >&2
  exit 2
}

cleanup() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" >/dev/null 2>&1; then
    kill "$app_pid" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "$app_pid" >/dev/null 2>&1 || true
  fi
  [[ -n "$heartbeat_file" ]] && rm -f "$heartbeat_file"
  [[ -n "$launch_log" ]] && rm -f "$launch_log"
  [[ -n "$pre_reports_file" ]] && rm -f "$pre_reports_file"
  [[ -n "$post_reports_file" ]] && rm -f "$post_reports_file"
}
trap cleanup EXIT INT TERM

collect_reports() {
  local out_file="$1"
  if [[ ! -d "$REPORT_DIR" ]]; then
    : >"$out_file"
    return
  fi
  find "$REPORT_DIR" -maxdepth 1 -type f \
    \( -name 'DevStation*.ips' -o -name 'DevStation*.crash' -o -name 'DevStation*.spin' -o -name 'DevStation*.hang' \) \
    -print 2>/dev/null | sort >"$out_file"
}

latest_heartbeat_seconds() {
  local file="$1"
  local raw
  raw="$(tail -n 1 "$file" 2>/dev/null || true)"
  [[ -z "$raw" ]] && return 1
  awk -v val="$raw" 'BEGIN { if (val == "") exit 1; printf "%d", val }'
}

ensure_app_binary() {
  if [[ -x "$APP_BIN" ]]; then
    return
  fi

  echo "check-devstation-performance: building DevStation debug binary..."
  xcodebuild \
    -project "$REPO_ROOT/apps/dev-station/DevStation.xcodeproj" \
    -scheme DevStation \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO >/tmp/sods-check-devstation-performance.build.log 2>&1 || {
      cat /tmp/sods-check-devstation-performance.build.log >&2
      fail "xcodebuild failed while preparing DevStation binary"
    }
}

ensure_app_binary

run_id="sods-perf-$(date +%s)-$$"
heartbeat_file="$(mktemp /tmp/sods-ui-heartbeat.XXXXXX)"
launch_log="$(mktemp /tmp/sods-devstation-perf-launch.XXXXXX.log)"
pre_reports_file="$(mktemp /tmp/sods-devstation-perf-reports-pre.XXXXXX)"
post_reports_file="$(mktemp /tmp/sods-devstation-perf-reports-post.XXXXXX)"
collect_reports "$pre_reports_file"

SODS_UI_HEARTBEAT_PATH="$heartbeat_file" \
  open -n "$APP_BUNDLE" --args --perf-run-id "$run_id" --start-view ble --roundup status --station "$STATION_URL" >"$launch_log" 2>&1 || {
    cat "$launch_log" >&2
    fail "failed to launch DevStation via open -n"
  }

boot_deadline=$(( $(date +%s) + BOOT_TIMEOUT_SECONDS ))
while (( $(date +%s) < boot_deadline )); do
  if [[ -z "$app_pid" ]]; then
    app_pid="$(pgrep -f "/DevStation.app/Contents/MacOS/DevStation --perf-run-id $run_id" | head -n 1 || true)"
  fi
  if [[ -n "$app_pid" ]] && ! kill -0 "$app_pid" >/dev/null 2>&1; then
    fail "DevStation exited during startup"
  fi

  hb_secs="$(latest_heartbeat_seconds "$heartbeat_file" || true)"
  if [[ -n "$app_pid" && -n "$hb_secs" ]]; then
    break
  fi
  sleep 1
done

[[ -n "$app_pid" ]] || fail "unable to resolve launched DevStation pid for run_id=$run_id"
hb_secs="$(latest_heartbeat_seconds "$heartbeat_file" || true)"
[[ -n "$hb_secs" ]] || fail "heartbeat file was not updated within startup timeout"

cpu_sum="0"
sample_count=0
baseline_rss=-1
max_rss=0

for ((elapsed = 0; elapsed < SAMPLE_SECONDS; elapsed += sample_interval)); do
  sleep "$sample_interval"

  kill -0 "$app_pid" >/dev/null 2>&1 || {
    cat "$launch_log" >&2
    fail "DevStation terminated before sample window completed"
  }

  hb_secs="$(latest_heartbeat_seconds "$heartbeat_file" || true)"
  [[ -n "$hb_secs" ]] || fail "heartbeat file became unreadable"

  now_secs="$(date +%s)"
  heartbeat_age=$(( now_secs - hb_secs ))
  if (( heartbeat_age > HEARTBEAT_STALE_SECONDS )); then
    fail "heartbeat stale for ${heartbeat_age}s (threshold ${HEARTBEAT_STALE_SECONDS}s)"
  fi

  cpu="$(ps -p "$app_pid" -o %cpu= | awk '{print $1}' || true)"
  rss="$(ps -p "$app_pid" -o rss= | awk '{print $1}' || true)"
  [[ -n "$cpu" && -n "$rss" ]] || fail "unable to sample CPU/RSS for pid $app_pid"

  cpu_sum="$(awk -v sum="$cpu_sum" -v value="$cpu" 'BEGIN { printf "%.3f", sum + value }')"
  sample_count=$((sample_count + 1))

  rss_kb="${rss%%.*}"
  if (( baseline_rss < 0 )); then
    baseline_rss="$rss_kb"
  fi
  if (( rss_kb > max_rss )); then
    max_rss="$rss_kb"
  fi
done

avg_cpu="$(awk -v sum="$cpu_sum" -v n="$sample_count" 'BEGIN { if (n == 0) print "0"; else printf "%.3f", sum / n }')"
rss_delta=$(( max_rss - baseline_rss ))

awk -v avg="$avg_cpu" -v limit="$CPU_MAX_AVG" 'BEGIN { if (avg > limit) exit 1; exit 0 }' || \
  fail "average CPU ${avg_cpu}% exceeded limit ${CPU_MAX_AVG}%"

(( max_rss <= RSS_MAX_KB )) || fail "peak RSS ${max_rss}KB exceeded limit ${RSS_MAX_KB}KB"
(( rss_delta <= RSS_DELTA_MAX_KB )) || fail "RSS delta ${rss_delta}KB exceeded limit ${RSS_DELTA_MAX_KB}KB"

collect_reports "$post_reports_file"
new_reports="$(comm -13 "$pre_reports_file" "$post_reports_file" || true)"
if [[ -n "$new_reports" ]]; then
  echo "$new_reports" >&2
  fail "new DevStation crash/spin report detected during performance run"
fi

echo "check-devstation-performance: PASS (avg_cpu=${avg_cpu}% peak_rss_kb=${max_rss} rss_delta_kb=${rss_delta})"
exit 0
